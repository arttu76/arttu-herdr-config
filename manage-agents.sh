#!/usr/bin/env bash
# Single-prompt agent management popup (prefix+A).
# `manage-agents.sh --toggle` (prefix+a, detached) runs only the empty-input toggle without a popup.
#   (empty)            toggle focus: from a non-agent pane go to the last focused agent,
#                      from an agent pane go to the previously focused agent
#   <n>question        ask agent #n (sends to its input without focusing it)
#   r<n>new-name       rename agent #n ("-" clears the name). Spaces are optional;
#                      spaces inside the name become "-", upper case becomes lower case.
# Usage: manage-agents.sh              interactive (lists agents, one prompt)
#        manage-agents.sh <line...>    non-interactive, same syntax as the prompt
# Shared grammar, colours, focus history and dispatch live in manage-lib.sh.
set -euo pipefail
# shellcheck source=manage-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/manage-lib.sh"
KIND=agent

# lines: "<pane_id>\t<mark>\t<display text>" (no headers). One herdr call.
SNAP_FOCUS='.focused_pane_id' SNAP_IDS='.agents[].pane_id'   # --toggle fast path (jq)
build_lines() {
  mapfile -t lines < <(herdr api snapshot | python3 -I -c '
import json, os, sys
E = os.environ.get
def paint(code, s, cur): return s if (cur or not s) else E(code, "") + s + E("C_END", "")
def status(s, cur): return paint("C_WORKING" if s == "working" else "C_BLOCKED" if s == "blocked" else "C_DIM", s, cur)
snap = json.load(sys.stdin)["result"]["snapshot"]
home = os.path.expanduser("~")
for a in snap["agents"]:
    focused = a["pane_id"] == snap.get("focused_pane_id")
    mark = "*" if focused else " "
    cwd = paint("C_DIM", (a.get("cwd") or "").replace(home, "~", 1), focused)
    title = paint("C_DIM", a.get("terminal_title_stripped") or "", focused)
    cols = [a.get("name") or "-", a.get("agent", "?"), status(a.get("agent_status", "?"), focused), cwd, title]
    print(f"{a["pane_id"]}\t{mark}\t" + "  ".join(c for c in cols if c))
  ')
}

item_focus() { herdr agent focus "$1" >/dev/null; }
item_ask() { herdr agent prompt "$1" "$2" >/dev/null; }
item_rename() { herdr agent rename "$1" "$2" >/dev/null; }
item_clear() { herdr agent rename "$1" --clear >/dev/null; }
normalize_name() {   # agent names: lowercase, no spaces, [a-z][a-z0-9_-]{0,31}
  local name; name=$(tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[[:space:]]+/-/g; s/^-+//; s/-+$//')
  [[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || fail "invalid name: must match [a-z][a-z0-9_-]{0,31}"
  echo "$name"
}

run_popup "$@"
