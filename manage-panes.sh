#!/usr/bin/env bash
# Single-prompt pane management popup (prefix+P). Lists panes from all workspaces.
# `manage-panes.sh --toggle` (prefix+p, detached) runs only the empty-input toggle without a popup.
#   (empty)             back to the previously focused pane (focus history, crosses workspaces)
#   <n>                 switch to pane #n, switching workspace if needed
#   n [name]            split the focused pane (right if wide, down if tall), focus it, optionally name it
#   r<n>new-name        rename pane #n ("-" clears, spaces allowed). Spaces after r<n> are optional.
#   D<n>                close pane #n (uppercase D on purpose, no undo)
# Usage: manage-panes.sh              interactive (lists panes, one prompt)
#        manage-panes.sh <line...>    non-interactive, same syntax as the prompt
# Shared grammar, colours, focus history and dispatch live in manage-lib.sh.
set -euo pipefail
# shellcheck source=manage-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/manage-lib.sh"
KIND=pane NEW_HINT="new pane (split)"

# lines: "#\t<workspace header>" or "<pane_id>\t<mark>\t<display text>". One herdr call.
SNAP_FOCUS='.focused_pane_id' SNAP_IDS='.panes[].pane_id'   # --toggle fast path (jq)
build_lines() {
  mapfile -t lines < <(herdr api snapshot | python3 -I -c '
import json, os, sys
E = os.environ.get
def paint(code, s, cur): return s if (cur or not s) else E(code, "") + s + E("C_END", "")
def status(s, cur): return paint("C_WORKING" if s == "working" else "C_BLOCKED" if s == "blocked" else "C_DIM", s, cur)
snap = json.load(sys.stdin)["result"]["snapshot"]
home = os.path.expanduser("~")
ws = {w["workspace_id"]: w for w in snap["workspaces"]}
panes = snap["panes"]
order = list(ws) + [p["workspace_id"] for p in panes if p["workspace_id"] not in ws]
for wid in dict.fromkeys(order):
    group = [p for p in panes if p["workspace_id"] == wid]
    if not group: continue
    label = (ws.get(wid, {}).get("label") or "").strip() or "-"
    print(f"#\t{label} ({wid})")
    for p in group:
        focused = p["pane_id"] == snap.get("focused_pane_id")
        mark = "*" if focused else " "
        cwd = paint("C_DIM", (p.get("foreground_cwd") or p.get("cwd") or "").replace(home, "~", 1), focused)
        agent = p.get("agent") or ""
        if agent and p.get("name"): agent += ":" + p["name"]
        if agent: agent += " [" + status(p.get("agent_status", "?"), focused) + "]"
        title = paint("C_DIM", p.get("terminal_title_stripped") or "", focused)
        cols = [p["pane_id"], p.get("label") or "", agent, cwd, title]
        print(f"{p["pane_id"]}\t{mark}\t" + "  ".join(c for c in cols if c))
  ')
}

# `herdr pane focus` only moves by direction; the socket API's pane.focus takes an id and also
# switches workspace.
item_focus() {
  python3 -I - "$1" <<'PY'
import json, os, socket, sys
pane_id = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5)
s.connect(os.environ["HERDR_SOCKET_PATH"])
s.sendall((json.dumps({"id": "manage-panes", "method": "pane.focus", "params": {"pane_id": pane_id}}) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    c = s.recv(65536)
    if not c: break
    buf += c
r = json.loads(buf or b"{}")
if "error" in r:
    print(json.dumps(r["error"]), file=sys.stderr); sys.exit(1)
PY
}

# Split the focused pane (right if it is at least twice as wide as tall, else down), inherit
# its cwd, focus the new pane, then name it.
item_create() {
  local pane cwd direction args out new
  read -r pane cwd < <(herdr pane list | python3 -I -c '
import json, sys
for p in json.load(sys.stdin)["result"]["panes"]:
    if p.get("focused"):
        print(p["pane_id"], p.get("foreground_cwd") or p.get("cwd") or ""); break
')
  [[ -n ${pane:-} ]] || return 1
  direction=$(herdr pane layout --pane "$pane" | python3 -I -c '
import json, sys
pid = sys.argv[1]
for p in json.load(sys.stdin)["result"]["layout"]["panes"]:
    if p["pane_id"] == pid:
        r = p["rect"]; print("right" if r["width"] >= 2 * r["height"] else "down"); break
else:
    print("right")
' "$pane")
  args=(--direction "$direction" --focus); [[ -n $cwd ]] && args+=(--cwd "$cwd")
  out=$(herdr pane split "$pane" "${args[@]}") || return 1
  new=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])' <<<"$out")
  remember pane "$new"
  [[ -z $1 ]] || herdr pane rename "$new" "$1" >/dev/null || fail "created $new but failed to name it"
}
item_rename() { herdr pane rename "$1" "$2" >/dev/null; }
item_clear() { herdr pane rename "$1" --clear >/dev/null; }
item_close() { herdr pane close "$1" >/dev/null; }

run_popup "$@"
