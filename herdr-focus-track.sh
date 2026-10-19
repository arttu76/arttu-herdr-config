#!/usr/bin/env bash
# Focus tracker daemon for the prefix+p/t/w/a toggles (see manage-lib.sh). Subscribes to
# Herdr's pane/tab/workspace focus events over $HERDR_SOCKET_PATH and writes the focus history
# files the moment focus changes, however it changed. Also keeps tab labels suffixed with
# their position in the workspace ("name(2)", prefix+2 switches to it): re-applied to the
# whole workspace on tab.created/closed/moved/renamed, since positions shift.
# herdr-pane-info.sh starts this on every tab bar refresh; a lock (fcntl.flock below) keeps
# one instance alive and a pid file lets the starter skip the spawn. It exits when the socket
# closes (server restart), to be restarted by the next refresh.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/manage-lib.sh"
[[ -n ${HERDR_SOCKET_PATH:-} ]] || exit 0
mkdir -p "$HIST_DIR"
exec python3 -I - "$HIST_DIR" <<'PY'
import json, os, re, socket, subprocess, sys
import fcntl
HIST_DIR = sys.argv[1]
# One instance: flock(2) on the lock file, held for the life of this process (the fd stays open).
# Done in python rather than flock(1), which is util-linux and missing on macOS.
LOCK = open(os.path.join(HIST_DIR, "focus-track.lock"), "w")
try: fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError: sys.exit(0)   # already running
PID_FILE = os.path.join(HIST_DIR, "focus-track.pid")   # read by herdr-pane-info.sh (kill -0)
with open(PID_FILE, "w") as fh: fh.write(str(os.getpid()))

def remember(kind, id_):   # same file format as remember() in manage-lib.sh
    f = os.path.join(HIST_DIR, f"{kind}-focus")
    try: old = [l for l in open(f).read().split("\n") if l]
    except FileNotFoundError: old = []
    new = ([id_] + [x for x in old if x != id_])[:20]
    tmp = f"{f}.{os.getpid()}"
    with open(tmp, "w") as fh: fh.write("\n".join(new) + "\n")
    os.replace(tmp, f)

def herdr(*args):
    try: return json.loads(subprocess.run(["herdr", *args], capture_output=True, text=True).stdout)["result"]
    except Exception: return {}

def fix_label(tab, pos):   # "name" -> "name(<position>)"; default labels (a bare number) are left alone
    label = tab.get("label") or ""
    base = re.sub(r"\s*\(\d+\)$", "", label).strip()
    if not base or base.isdigit() or not tab.get("tab_id"): return
    want = f"{base}({pos})"
    if want != label: herdr("tab", "rename", tab["tab_id"], want)

def fix_tabs(tabs):
    for pos, t in enumerate(tabs, 1): fix_label(t, pos)

def fix_workspace(wid):
    if wid: fix_tabs(herdr("tab", "list", "--workspace", wid).get("tabs", []))

def is_agent(pane_id):
    return any(a["pane_id"] == pane_id for a in herdr("agent", "list").get("agents", []))

# Seed from the current state so the history is right immediately after (re)start.
snap = herdr("api", "snapshot").get("snapshot", {})
for kind, key in (("workspace", "focused_workspace_id"), ("tab", "focused_tab_id"), ("pane", "focused_pane_id")):
    if snap.get(key): remember(kind, snap[key])
if snap.get("focused_pane_id") and any(a["pane_id"] == snap["focused_pane_id"] for a in snap.get("agents", [])):
    remember("agent", snap["focused_pane_id"])
for w in snap.get("workspaces", []):
    fix_tabs([t for t in snap.get("tabs", []) if t.get("workspace_id") == w["workspace_id"]])

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.environ["HERDR_SOCKET_PATH"])
subs = [{"type": t} for t in ("pane.focused", "tab.focused", "workspace.focused",
                              "tab.created", "tab.closed", "tab.moved", "tab.renamed")]
s.sendall((json.dumps({"id": "focus-track", "method": "events.subscribe", "params": {"subscriptions": subs}}) + "\n").encode())
buf = b""
while True:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        try: msg = json.loads(line)
        except Exception: continue
        data = msg.get("data") or {}; ev = msg.get("event") or data.get("type")
        if ev == "pane_focused" and data.get("pane_id"):
            remember("pane", data["pane_id"])
            if is_agent(data["pane_id"]): remember("agent", data["pane_id"])
        elif ev == "tab_focused" and data.get("tab_id"): remember("tab", data["tab_id"])
        elif ev == "workspace_focused" and data.get("workspace_id"): remember("workspace", data["workspace_id"])
        elif ev in ("tab_created", "tab_closed", "tab_moved", "tab_renamed"):
            fix_workspace(data.get("workspace_id") or (data.get("tab") or {}).get("workspace_id"))
try: os.remove(PID_FILE)
except OSError: pass
PY
