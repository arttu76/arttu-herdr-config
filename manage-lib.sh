#!/usr/bin/env bash
# Shared core of manage-agents.sh, manage-panes.sh, manage-tabs.sh and manage-workspaces.sh.
# Sourced, never run. The calling script (which has set -euo pipefail) provides:
#   KIND       agent | pane | tab | workspace   (messages, history file "$HIST_DIR/$KIND-focus")
#   NEW_HINT   text after "n[name] =" in the prompt hint (only with item_create)
#   build_lines  function filling lines[]: "#<TAB>header" or "<id><TAB><mark><TAB>display text",
#              mark "*" = current item (one `herdr api snapshot | python3` call)
#   SNAP_FOCUS, SNAP_IDS   jq paths into .result.snapshot for the focused id and the ids in
#              list order; the --toggle fast path uses them instead of build_lines when jq exists
# and these hook functions (optional ones enable the matching grammar):
#   item_focus id            switch to the item
#   item_create name         "n [name]"  (optional)
#   item_rename id name      "r<n>name"
#   normalize_name name id   prints the name actually used, or calls fail (optional: agents
#                            lowercase/validate, tabs append the tab number)
#   item_clear id            "r<n>-" clears the name (optional)
#   item_close id            "D<n>"      (optional)
#   item_ask id text         "<n>text" sends text instead of switching; bare "<n>" is then an
#                            error (optional, agents only)
# then calls run_popup "$@". "--toggle" as the only argument equals an empty prompt line.

# bash >= 4 (mapfile, BASH_REMATCH arrays). macOS ships 3.2 as /bin/bash, hence the
# `#!/usr/bin/env bash` shebangs: a newer bash must be first on PATH (brew install bash).
if (( BASH_VERSINFO[0] < 4 )); then
  echo "herdr scripts need bash >= 4, found $BASH_VERSION (macOS: brew install bash)" >&2; sleep 2; exit 1
fi

# Colours: only when stdout is a terminal and NO_COLOR is unset. C_* are exported for the
# python list builders (status/cwd/title tints). Everything delete-related is bold bright red.
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C0=$'\e[0m' CB=$'\e[1m' CD=$'\e[2m' CNUM=$'\e[1m'
  CCUR=$'\e[1;96m'   # current item (whole line + marker): bold bright cyan
  CHDR=$'\e[1;34m'   # workspace headers
  CNEW=$'\e[32m' CREN=$'\e[33m' COK=$'\e[32m'
  CDEL=$'\e[1;91m'   # close key, "closed" messages and errors
  export C_WORKING=$'\e[32m' C_BLOCKED=$'\e[1;93m' C_DIM=$'\e[2m' C_END=$'\e[0m'
else
  C0= CB= CD= CNUM= CCUR= CHDR= CNEW= CREN= COK= CDEL=
fi

fail() { printf '%s%s%s\n' "$CDEL" "$*" "$C0" >&2; sleep 2; exit 1; }
trim() { sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' <<<"$1"; }

# Focus history, most recent first, one file per kind. Herdr has no focus history API, so the
# popups record what they focus and herdr-focus-track.sh (run by the tab bar command every 2 s)
# records focus changes made any other way.
HIST_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
remember() {   # remember <kind> <id>
  local f="$HIST_DIR/$1-focus" rest
  mkdir -p "$HIST_DIR"; touch "$f"
  rest=$(grep -vxF -- "$2" "$f" || true)
  { echo "$2"; [[ -n $rest ]] && echo "$rest"; } | head -20 > "$f.$$" || true
  mv "$f.$$" "$f"
}

# The item focused before the current one: newest history entry that still exists and is not
# current; without one, the previous item in list order (wrapping), or the first item when
# nothing is current. Prints the id.
previous_item() {
  local h id
  while read -r h; do
    [[ -n $h && $h != "$current" ]] || continue
    for id in "${ids[@]}"; do [[ $id == "$h" ]] && { echo "$h"; return; }; done
  done < <(cat "$HIST_DIR/$KIND-focus" 2>/dev/null || true)
  local cur=0 i
  for i in "${!ids[@]}"; do [[ ${ids[$i]} == "$current" ]] && cur=$i; done
  echo "${ids[$(( (cur - 1 + ${#ids[@]}) % ${#ids[@]} ))]}"
}

show_list() {
  local i=1 l h mark text
  for l in "${lines[@]}"; do
    if [[ $l == "#"$'\t'* ]]; then h=${l#*$'\t'}; printf '\n%s%s%s\n' "$CHDR" "${h%\*}" "$C0"
    else
      IFS=$'\t' read -r _ mark text <<<"$l"
      if [[ $mark == "*" ]]; then printf '%s%2d) ▶ %s%s\n' "$CCUR" "$i" "$text" "$C0"
      else printf '%s%2d)%s   %s\n' "$CNUM" "$i" "$C0" "$text"; fi
      ((i++))
    fi
  done
}

has() { declare -F "$1" >/dev/null; }

hint() {
  local h
  if has item_ask; then h="${CD}Ask $KIND by ${C0}${CNEW}[number]question${C0}"
  else h="${CD}Switch by number${C0}"; fi
  has item_create && h+="${CD}, ${C0}${CNEW}n[name]${C0}${CD} = ${NEW_HINT:-new $KIND}${C0}"
  h+="${CD}, ${C0}${CREN}r[number]new-name${C0}${CD} = rename"; has item_clear && h+=" (- clears)"; h+="${C0}"
  has item_close && h+="${CD}, ${C0}${CDEL}D[number] = close${C0}"
  h+=" ${CD}(${C0}${CCUR}▶${C0}${CD} = current, empty = previous $KIND)${C0}"
  printf '%s\n' "$h"
}

usage() {   # the accepted forms, for "bad input" messages
  local u
  if has item_ask; then u="'<n>question'"; else u="'<n>'"; fi
  has item_create && u+=", 'n [name]'"
  u+=", 'r<n>new-name'"
  has item_close && u+=", 'D<n>'"
  sed -E 's/,([^,]*)$/ or\1/' <<<"$u"
}

run_popup() {
  local fast="" l id mark line name n arg mode target
  [[ ${1:-} == --toggle ]] && { set -- ""; fast=1; }
  rows=(); ids=(); current=""
  if [[ -n $fast && -n ${SNAP_IDS:-} ]] && command -v "${MANAGE_JQ:-jq}" >/dev/null; then
    # Toggle fast path: no display text needed, and jq starts much faster than python.
    mapfile -t ids < <(herdr api snapshot | "${MANAGE_JQ:-jq}" -r ".result.snapshot | (${SNAP_FOCUS:-empty} // \"\"), ${SNAP_IDS}")
    current=${ids[0]:-}; ids=("${ids[@]:1}"); rows=("${ids[@]}")
    local found=""; for id in "${ids[@]}"; do [[ $id == "$current" ]] && found=1; done
    [[ -n $found ]] || current=""   # e.g. the focused pane is not an agent
  else
    build_lines
    for l in "${lines[@]}"; do
      [[ $l == "#"$'\t'* ]] && continue
      rows+=("$l"); IFS=$'\t' read -r id mark _ <<<"$l"; ids+=("$id")
      [[ $mark == "*" ]] && current=$id
    done
  fi
  [[ ${#rows[@]} -gt 0 ]] || fail "no ${KIND}s"
  [[ -n $current ]] && remember "$KIND" "$current"

  if [[ $# -ge 1 ]]; then
    line="$*"
  else
    show_list; echo; hint
    read -rp "${CB}> ${C0}" line
  fi

  # Empty: back to the previously focused item.
  if [[ -z "${line// /}" ]]; then
    target=$(previous_item)
    [[ $target != "$current" ]] || exit 0
    item_focus "$target" || fail "failed to focus $target"
    remember "$KIND" "$target"
    exit 0
  fi

  if has item_create && [[ $line =~ ^[[:space:]]*n[[:space:]]*(.*)$ ]]; then
    name=$(trim "${BASH_REMATCH[1]}")
    item_create "$name" || fail "failed to create $KIND"
    exit 0
  fi

  # Closing always needs an explicit number; a bare "D" never falls back to the current item.
  if has item_close && [[ $line =~ ^[[:space:]]*D[[:space:]]*$ ]]; then
    fail "close needs a number: D<n> (nothing closed)"
  fi

  if [[ $line =~ ^[[:space:]]*([rD]?)([0-9]+)[[:space:]]*(.*)$ ]]; then
    mode=${BASH_REMATCH[1]}; n=${BASH_REMATCH[2]}; arg=${BASH_REMATCH[3]}
  else
    fail "bad input: expected $(usage)"
  fi
  [[ $n -ge 1 && $n -le ${#rows[@]} ]] || fail "no $KIND #$n (1-${#rows[@]})"
  target=${ids[$((n-1))]}

  if [[ $mode == D ]]; then
    has item_close || fail "bad input: expected $(usage)"
    [[ -z "${arg// /}" ]] || fail "bad input: closing takes only a number: D<n>"
    item_close "$target" || fail "failed to close $target"
    printf '%sclosed #%s (%s)%s\n' "$CDEL" "$n" "$target" "$C0"
    sleep 1; exit 0
  fi

  if [[ -z $mode ]]; then
    if has item_ask; then
      [[ -n "${arg// /}" ]] || fail "ask needs a question: <n>question"
      item_ask "$target" "$arg" || fail "failed to send to $target"
      printf '%ssent to #%s (%s)%s\n' "$COK" "$n" "$target" "$C0"
      sleep 1; exit 0
    fi
    [[ -z "${arg// /}" ]] || fail "bad input: switching takes only a number"
    item_focus "$target" || fail "failed to focus $target"
    remember "$KIND" "$target"
    exit 0
  fi

  arg=$(trim "$arg")
  [[ -n $arg ]] || fail "rename needs a new name: r<n>new-name$(has item_clear && printf " ('-' clears)")"
  if [[ $arg == "-" ]] && has item_clear; then
    item_clear "$target" || fail "failed to clear name of $target"
    printf '%scleared name of #%s (%s)%s\n' "$COK" "$n" "$target" "$C0"
  else
    if has normalize_name; then arg=$(normalize_name "$arg" "$target") || exit 1; fi
    item_rename "$target" "$arg" || fail "failed to rename $target"
    printf '%srenamed #%s (%s) -> %s%s\n' "$COK" "$n" "$target" "$arg" "$C0"
  fi
  # A renamed item is the one you are about to work with: switch to it.
  item_focus "$target" || fail "renamed, but failed to focus $target"
  remember "$KIND" "$target"
  sleep 1
}
