#!/usr/bin/env bash
# Single-prompt workspace management popup (prefix+W).
# `manage-workspaces.sh --toggle` (prefix+w, detached) runs only the empty-input toggle without a popup.
#   (empty)             back to the previously focused workspace (focus history)
#   <n>                 switch to workspace #n
#   n [name]            create a workspace, optionally named
#   r<n>new-name        rename workspace #n (spaces allowed in labels). Spaces after r<n> are optional.
#   D<n>                close workspace #n (uppercase D on purpose, no undo)
# Usage: manage-workspaces.sh              interactive (lists workspaces, one prompt)
#        manage-workspaces.sh <line...>    non-interactive, same syntax as the prompt
# Shared grammar, colours, focus history and dispatch live in manage-lib.sh.
set -euo pipefail
# shellcheck source=manage-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/manage-lib.sh"
KIND=workspace NEW_HINT="new workspace"

# lines: "<workspace_id>\t<mark>\t<display text>" (no headers). One herdr call.
SNAP_FOCUS='.focused_workspace_id' SNAP_IDS='.workspaces[].workspace_id'   # --toggle fast path (jq)
build_lines() {
  mapfile -t lines < <(herdr api snapshot | python3 -I -c '
import json, os, sys
E = os.environ.get
def paint(code, s, cur): return s if (cur or not s) else E(code, "") + s + E("C_END", "")
def status(s, cur): return paint("C_WORKING" if s == "working" else "C_BLOCKED" if s == "blocked" else "C_DIM", s, cur)
snap = json.load(sys.stdin)["result"]["snapshot"]
for w in snap["workspaces"]:
    focused = w["workspace_id"] == snap.get("focused_workspace_id")
    mark = "*" if focused else " "
    counts = paint("C_DIM", f"{w.get("tab_count", 0)} tabs  {w.get("pane_count", 0)} panes", focused)
    print(f"{w["workspace_id"]}\t{mark}\t{w.get("label") or "-"}  {counts}  {status(w.get("agent_status") or "", focused)}")
  ')
}

item_focus() { herdr workspace focus "$1" >/dev/null; }
item_create() {
  local args=(--focus); [[ -n $1 ]] && args+=(--label "$1")
  herdr workspace create "${args[@]}" >/dev/null
}
item_rename() { herdr workspace rename "$1" "$2" >/dev/null; }
item_close() { herdr workspace close "$1" >/dev/null; }

run_popup "$@"
