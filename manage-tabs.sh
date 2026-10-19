#!/usr/bin/env bash
# Single-prompt tab management popup (prefix+T). Lists tabs from all workspaces.
# `manage-tabs.sh --toggle` (prefix+t, detached) runs only the empty-input toggle without a popup.
#   (empty)             back to the previously focused tab (focus history, crosses workspaces)
#   <n>                 switch to tab #n, switching workspace if needed
#   n [name]            create a tab in the current workspace, optionally named
#   r<n>new-name        rename tab #n (spaces allowed). Spaces after r<n> are optional.
#   D<n>                close tab #n (uppercase D on purpose, no undo)
# Tab labels carry the tab's position in its workspace as a suffix, "name(2)", because prefix+2
# switches to the 2nd tab; renames and creates add it here, herdr-focus-track.sh keeps it right
# for tabs made, closed or moved elsewhere.
# Usage: manage-tabs.sh              interactive (lists tabs, one prompt)
#        manage-tabs.sh <line...>    non-interactive, same syntax as the prompt
# Shared grammar, colours, focus history and dispatch live in manage-lib.sh.
set -euo pipefail
# shellcheck source=manage-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/manage-lib.sh"
KIND=tab NEW_HINT="new tab here"

# lines: "#\t<workspace header>" or "<tab_id>\t<mark>\t<display text>"; the first line is
# "@<focused workspace id>" and is stripped below. One herdr call for everything.
SNAP_FOCUS='.focused_tab_id' SNAP_IDS='.tabs[].tab_id'   # --toggle fast path (jq)
build_lines() {
  mapfile -t lines < <(herdr api snapshot | python3 -I -c '
import json, os, re, sys
E = os.environ.get
def paint(code, s, cur): return s if (cur or not s) else E(code, "") + s + E("C_END", "")
def status(s, cur): return paint("C_WORKING" if s == "working" else "C_BLOCKED" if s == "blocked" else "C_DIM", s, cur)
snap = json.load(sys.stdin)["result"]["snapshot"]
print("@" + (snap.get("focused_workspace_id") or ""))
for w in snap["workspaces"]:
    wid = w["workspace_id"]
    tabs = [t for t in snap["tabs"] if t["workspace_id"] == wid]
    if not tabs: continue
    print(f"#\t{(w.get("label") or "").strip() or "-"} ({wid})")
    for pos, t in enumerate(tabs, 1):
        focused = t["tab_id"] == snap.get("focused_tab_id")
        mark = "*" if focused else " "
        label = t.get("label") or "-"
        if not label.isdigit() and not label.endswith(f"({pos})"): label += paint("C_DIM", f"({pos})", focused)
        panes = paint("C_DIM", f"{t.get("pane_count", 0)} panes", focused)
        print(f"{t["tab_id"]}\t{mark}\t{label}  {panes}  {status(t.get("agent_status") or "", focused)}")
  ')
  current_ws=${lines[0]#@}; lines=("${lines[@]:1}")
}

# "name(<position>)": strip a stale "(n)" suffix first; a bare number (Herdr's default label)
# stays as it is.
numbered() {   # numbered <name> <position>
  local base; base=$(sed -E 's/[[:space:]]*\([0-9]+\)$//' <<<"$1")
  if [[ -n $base && -n $2 && ! $base =~ ^[0-9]+$ ]]; then echo "$base($2)"; else echo "$1"; fi
}
position() {   # position <tab_id>: 1-based index in its workspace's tab list
  herdr tab list --workspace "${1%%:*}" | python3 -I -c '
import json, sys
ids = [t["tab_id"] for t in json.load(sys.stdin)["result"]["tabs"]]
print(ids.index(sys.argv[1]) + 1 if sys.argv[1] in ids else "")' "$1"
}
normalize_name() {   # normalize_name <name> <tab_id>
  local pos; pos=$(position "$2") && [[ -n $pos ]] || fail "failed to read tab $2"
  numbered "$1" "$pos"
}

# Focus the tab's workspace first: `tab focus` alone may not cross workspaces.
current_ws=""
item_focus() {
  local ws=${1%%:*}
  [[ -n $current_ws ]] || current_ws=${current%%:*}   # fast path: no build_lines ran
  [[ $ws == "$current_ws" ]] || herdr workspace focus "$ws" >/dev/null || return 1
  herdr tab focus "$1" >/dev/null
}
item_create() {
  local args=(--focus) out new
  [[ -n $current_ws ]] && args+=(--workspace "$current_ws"); [[ -n $1 ]] && args+=(--label "$1")
  out=$(herdr tab create "${args[@]}") || return 1
  new=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])' <<<"$out") || return 0
  [[ -n ${new:-} ]] || return 0
  remember tab "$new"
  [[ -z $1 ]] || herdr tab rename "$new" "$(numbered "$1" "$(position "$new")")" >/dev/null || fail "created $new but failed to name it"
}
item_rename() { herdr tab rename "$1" "$2" >/dev/null; }
item_close() { herdr tab close "$1" >/dev/null; }

run_popup "$@"
