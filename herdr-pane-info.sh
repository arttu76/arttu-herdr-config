#!/usr/bin/env bash
# Herdr counterpart of tmux-pane-border-format.sh.
# Herdr strips ANSI colours from status output, so this prints plain text.
#
# Usage:
#   herdr-pane-info.sh [dir]          full line: path, git branch/status/remote, commit hashes
#                                     (default dir: $HERDR_ACTIVE_PANE_CWD, then $PWD)
#   herdr-pane-info.sh --short [dir]  compact label for pane borders (path + branch + status)

# Side job: make sure the focus tracker daemon (focus history for the prefix+p/t/w/a toggles,
# tab number suffixes) is running. Only when run by the tab bar (HERDR_ACTIVE_PANE_ID set).
# The daemon gets its own session so herdr's command timeout cannot take it down, and it exits
# at once if one already runs (lock in herdr-focus-track.sh). The pid file is a cheap pre-check
# so this does not spawn a process on every 2 s refresh. setsid is util-linux (Linux only);
# macOS has none, so there python does the setsid+exec.
if [[ -n ${HERDR_ACTIVE_PANE_ID:-} ]]; then
  daemon="$(dirname "${BASH_SOURCE[0]}")/herdr-focus-track.sh"
  pidfile="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/focus-track.pid"
  if ! { read -r pid < "$pidfile" && kill -0 "$pid"; } 2>/dev/null; then
    if command -v setsid >/dev/null; then
      setsid -f "$daemon" >/dev/null 2>&1 </dev/null
    else
      ( python3 -I -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' "$daemon" >/dev/null 2>&1 </dev/null & )
    fi
  fi
fi

SHORT=0
DIR=""
for arg in "$@"; do
  case "$arg" in
    --short) SHORT=1 ;;
    *) DIR="$arg" ;;
  esac
done
DIR="${DIR:-${HERDR_ACTIVE_PANE_CWD:-$PWD}}"
cd "$DIR" 2>/dev/null || { echo "${DIR/#$HOME/\~}"; exit 0; }

PRETTY_PATH="${DIR/#$HOME/\~}"

if ! git rev-parse --git-dir &>/dev/null; then
  echo "$PRETTY_PATH  not repo"
  exit 0
fi

git_branch() {
  local ref
  ref=$(git symbolic-ref HEAD 2>/dev/null) || ref=$(git rev-parse --short HEAD 2>/dev/null) || return
  echo "${ref#refs/heads/}"
}

git_status_text() {
  local index status="" staged modified untracked
  index=$(git status --porcelain 2>/dev/null)
  if [[ -n "$index" ]]; then
    staged=$(grep -c '^[AMRD]. ' <<<"$index")
    modified=$(grep -c '^.[MTD] ' <<<"$index")
    untracked=$(grep -c -E '^\?\? ' <<<"$index")
    [[ $staged -gt 0 ]] && status="$status${status:+ }staged($staged)"
    [[ $modified -gt 0 ]] && status="$status${status:+ }modified($modified)"
    [[ $untracked -gt 0 ]] && status="$status${status:+ }untracked($untracked)"
    grep -q '^UU ' <<<"$index" && status="$status${status:+ }unmerged"
  else
    status="clean"
  fi

  local head
  head=$(git status --porcelain -b 2>/dev/null | head -1)
  local ahead=0 behind=0
  [[ "$head" == *ahead* ]] && { status="$status UNPUSHED"; ahead=1; }
  [[ "$head" == *behind* ]] && { status="$status BEHIND"; behind=1; }
  if [[ $ahead -eq 0 && $behind -eq 0 && "$head" == *...* ]]; then
    status="$status up-to-date"
  fi
  echo "$status"
}

git_remote_text() {
  local branch remote url short
  branch=$(git_branch)
  remote=$(git config --get "branch.$branch.remote" 2>/dev/null)
  if [[ -n "$remote" ]]; then
    url=$(git remote get-url --push "$remote" 2>/dev/null)
    if [[ -n "$url" ]]; then
      url="${url%.git}"
      if [[ "$url" == *:* && "$url" != *://* ]]; then
        short=$(sed 's/.*://' <<<"$url" | rev | cut -d'/' -f1-2 | rev)
      else
        short=$(rev <<<"$url" | cut -d'/' -f1-2 | rev)
      fi
      echo "origin:$short"
      return
    fi
  fi
  echo "no origin"
}

git_commits_text() {
  local default
  if git show-ref --verify --quiet refs/heads/main; then
    default=main
  elif git show-ref --verify --quiet refs/heads/master; then
    default=master
  else
    return
  fi
  local default_hash current_hash parent_hash
  default_hash=$(git rev-parse --short "$default" 2>/dev/null)
  current_hash=$(git rev-parse --short HEAD 2>/dev/null)
  parent_hash=$(git rev-parse --short HEAD~1 2>/dev/null)
  echo "$default_hash $parent_hash>$current_hash"
}

BRANCH=$(git_branch)
STATUS=$(git_status_text)

if [[ $SHORT -eq 1 ]]; then
  echo "$PRETTY_PATH  $BRANCH $STATUS"
else
  echo "$PRETTY_PATH  $BRANCH $STATUS $(git_remote_text)  $(git_commits_text)"
fi
