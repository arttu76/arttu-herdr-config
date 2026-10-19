# Herdr config folder

Personal Herdr setup shared between machines through git (github.com/arttu76/arttu-herdr-config,
public; the clone must live at `~/arttu-herdr-config`): `config.toml`, popup scripts,
`install.sh`, README. Used on Linux and macOS, so every script must work on both: bash via
`#!/usr/bin/env bash` (macOS /bin/bash is 3.2), no GNU-only flags (`sed -i ''` vs `sed -i`,
no `date -d`, `stat -c`, `readlink -f`), no `setsid`/`flock`/`timeout` without a fallback
(`herdr-pane-info.sh` falls back to python for setsid; the daemon locks with python `fcntl`).
`config.toml` refers to the scripts as `$HOME/arttu-herdr-config/...` (commands run through
`/bin/sh -c`); never bake a home directory into it.
`install.sh` symlinks the config, chmods `*.sh`, regenerates `skills/herdr/SKILL.md` (gitignored),
installs the plugins in its `PLUGINS` list and fails if a `type = "plugin_action"` key in
config.toml names a plugin missing from that list. A new plugin binding needs a `PLUGINS`
line and a row in the README Plugins table too.
Scripts are read on every keypress, so script edits are live at once; config edits need
`herdr server reload-config` (and `herdr config check` first).

## Management scripts: one shared core

`manage-agents.sh`, `manage-tabs.sh`, `manage-panes.sh`, `manage-workspaces.sh` are one
family built on `manage-lib.sh` (sourced). The lib owns everything that must stay identical:
colours, `fail`/`trim`, the list display, the prompt hint and "bad input" text, the prompt
grammar, the focus history and the dispatch (`run_popup`). A script only builds `lines`,
sets `KIND` (+ `NEW_HINT`) and defines the `item_*` hooks listed at the top of the lib.
**A behaviour change belongs in the lib unless it is inherent to the item type. If the user
asks for something that would make one script behave differently from the others, say so
and ask before implementing; do not special-case one script.** Divergence that is inherent
(agents can be asked, panes are split, tabs live in a workspace) is expressed by which
optional hooks a script defines, see "Allowed differences".

Key layout (config.toml `[keys]` + `[[keys.command]]`):
- `prefix+<lower>` = back to the previously focused item: a `type = "shell"` binding running
  `manage-<kind>.sh --toggle` (the empty-input path without a popup). Herdr's native
  `previous_*`/`cycle_pane_previous` keys cycle in list order, so they are unbound (`""`).
- `prefix+<Upper>` = management popup running the script (`type = "popup"`, 70%x50%; panes 80%x60%).
- Command strings run through `/bin/sh -c` on Unix, so arguments in `command = ...` work.
- Native `new_*`, `rename_*`, `workspace_picker` keys are unbound (`""`) because the popups cover them.
- Each binding has a comment in config.toml and rows in the README key table and script table.
  Update all three when behaviour changes.

Prompt grammar (one `read -rp "> "`, implemented once in `run_popup`):
- empty / whitespace  -> previously focused item: newest entry of the history file that still
  exists and is not current; with no usable history the previous item in list order (wrapping,
  crossing workspaces). `--toggle` as the only argument is the same.
- `<n>`               -> switch to item #n and remember it. Trailing text after a bare number is
  an error (agents: the trailing text is the question and is required, via `item_ask`).
- `n [name]`          -> create (only with `item_create`). Regex `^[[:space:]]*n[[:space:]]*(.*)$`,
  checked before the number regex.
- `r<n>[ ]name`       -> rename, then switch to the renamed item (all kinds). Regex
  `^[[:space:]]*([rD]?)([0-9]+)[[:space:]]*(.*)$`. `-` clears where `item_clear` exists (agents,
  panes). `normalize_name` (agents) lowercases, turns spaces into `-` and validates
  `[a-z][a-z0-9_-]{0,31}`.
- `D<n>`              -> close item #n (only with `item_close`: tabs, panes, workspaces).
  Uppercase D on purpose; trailing text is an error, and a bare `D` fails with "close needs a
  number" (checked before the number regex) so it never falls back to the current item.
- Names: `trim` collapses whitespace; tab/pane/workspace labels keep spaces.
- Non-interactive: `script.sh <line...>` takes the same line as arguments (used by tests).

Structure of every script, in this order:
1. `set -euo pipefail`; `source "$(dirname "${BASH_SOURCE[0]}")/manage-lib.sh"`; `KIND=...`;
   `SNAP_FOCUS`/`SNAP_IDS` (jq paths into `.result.snapshot`, e.g. `.focused_tab_id` and
   `.tabs[].tab_id`).
2. `build_lines()` filling `lines` via `herdr api snapshot | python3 -I -c '...'` (one herdr call: the snapshot
   has `workspaces`, `tabs`, `panes`, `agents` and `focused_*_id`; "current" = the focused id,
   not the per-item `focused` flag): tab-separated, **column 1 = id, column 2 = `*` for
   current else space**, rest = display text. Tabs/panes also emit workspace header lines
   starting with `#<TAB>`; tabs emit `@<focused workspace id>` as the first line and strip it
   into `current_ws`. Numbering is global across workspaces. The python starts with the shared
   `paint`/`status` helpers that tint status (`C_WORKING`, `C_BLOCKED`, else `C_DIM`), cwd and
   title through the exported `C_*` variables, and skips tinting on the current row because
   the whole row is highlighted. Keep the popups to one herdr call plus one python before the
   prompt. **The `--toggle` path never runs `build_lines`**: `run_popup` gets `current` and
   `ids` from `herdr api snapshot | jq` (`SNAP_FOCUS`, `SNAP_IDS`): the whole toggle is ~15 ms
   with jq and ~30 ms with python when idle, and python startup balloons to 80+ ms when agents
   load the machine; it falls back to `build_lines` when jq is missing
   (`MANAGE_JQ=/nonexistent` forces the fallback in tests). Anything the toggle needs that
   `build_lines` would have set (tabs: `current_ws`) must be derivable without it.
3. Hooks: `item_focus` (always), then the optional ones. Hooks return non-zero on failure and
   let the lib print the message; only `normalize_name` calls `fail` itself.
4. `run_popup "$@"`. Nothing else may run before it that costs time (no herdr calls at top level).

Lib behaviour worth knowing: `rows`, `ids`, `current` are derived from `lines`; the current
item is remembered at start; successful switches exit immediately; create exits immediately;
renames/asks/closes print a coloured line then `sleep 1`; "closed" and errors use `CDEL`
(bold bright red), the current row and the `▶` marker `CCUR`, headers `CHDR`. Colours are off
when stdout is not a tty or `NO_COLOR` is set.

Focusing: `herdr tab focus`/`workspace focus`/`agent focus` are CLI calls. `herdr pane focus`
is direction-only, so panes send `{"method":"pane.focus","params":{"pane_id":..}}` to
`$HERDR_SOCKET_PATH` (newline-delimited JSON) via inline python; that also switches workspace.
Tabs focus the workspace first, then the tab.

Focus history: `${XDG_STATE_HOME:-~/.local/state}/herdr/<kind>-focus` (agent, pane, tab,
workspace), most recent first, max 20, written by `remember <kind> <id>` (bash in the lib, the
same logic in python in the daemon). Herdr has no focus history API, but the socket API has
`events.subscribe` with `pane.focused`/`tab.focused`/`workspace.focused` (schema: `herdr api
schema --json`; events arrive as `{"event":"pane_focused","data":{...}}` lines on the same
connection). `herdr-focus-track.sh` is a daemon that seeds the history from `api snapshot`,
subscribes, and writes on every event (`herdr agent list` on pane focus to keep the agent
history). It is started with `setsid -f` from `herdr-pane-info.sh` on every tab bar refresh
(2 s, only when `HERDR_ACTIVE_PANE_ID` is set); `flock -n` on `focus-track.lock` makes the
extra starts exit at once, and the daemon exits on socket EOF so a server restart just
restarts it. `herdr-pane-info.sh` is also called from PROMPT_COMMAND without `HERDR_ACTIVE_*`,
which must stay a no-op.

Tab position suffix: `prefix+<n>` switches to the n-th tab of the workspace by **position**
(list order), not by the stable `number` the API reports (numbers are not reused, so a
workspace can show numbers 1 and 4 for its 1st and 2nd tab). Herdr labels new tabs with that
bare number. Labels are kept as `name(<position>)`: `manage-tabs.sh` applies it on rename
(`normalize_name`, position from `herdr tab list --workspace`) and on named create (same),
and the daemon applies it to every workspace at start and re-applies it to the whole
workspace on `tab.created`/`tab.closed`/`tab.moved`/`tab.renamed`, because positions shift.
Rule (same in both): strip a trailing `(digits)`, leave empty labels and bare-number labels
(Herdr's defaults) alone, else append `(<position>)`; idempotent, so the daemon's own renames
do not loop. The popup list shows a dim `(n)` for labels that lack it.

Allowed differences: agents have `item_ask` instead of `item_create`/`item_close` and
`normalize_name`; panes' `item_create` splits the focused pane (right if width >= 2*height
else down, inherits cwd, remembers the new pane, then renames); tabs' `item_create` creates in
the focused workspace and `item_focus` focuses the workspace first; workspaces have no headers.

## Pitfalls (these have bitten before)

- **Python inside `python3 -I -c '...'` (single-quoted bash string): never write `\"`.
  Bash passes the backslash through and python fails with "unexpected character after line
  continuation character" inside f-strings. Use plain `"` inside the single-quoted block;
  if you need a literal single quote, use `'"'"'`. For longer python prefer a quoted heredoc
  (`python3 -I - <<'PY' ... PY`), where no escaping is needed at all.**
- `set -e` + `&&` lists: `[[ cond ]] && func` exits the script if `func` is the last command
  and returns non-zero (e.g. `grep` finding nothing in an empty history file). Append
  `|| true` to greps that may legitimately match nothing.
- `herdr tab list` without `--workspace` only lists the focused workspace; iterate
  `workspace list` to get all tabs. `pane list` and `agent list` are global.
- Shell heredocs that embed `$'\t'`: when generating script text from python, `'\\t'` becomes
  `\t` in the file, which is what bash needs.

## Testing without touching the live session

Put a stub `herdr` script first in `PATH` that answers `api snapshot` (one canned snapshot
with `focused_*_id`, `workspaces`, `tabs` incl. `number`, `panes`, `agents`), `agent list`,
`pane list`, `tab get`, `tab create`, `pane layout`, `pane split` with canned JSON and echoes
every other call as `CALL: ...` to stderr (and to a log file: the daemon swallows subprocess
stderr). For panes also start a tiny unix-socket server at `$HERDR_SOCKET_PATH` that logs
`pane.focus` requests. Point `XDG_STATE_HOME` at a scratch dir for the focus history and set
`NO_COLOR=1` for stable output. Run each script non-interactively with every grammar form
plus the error cases, `--toggle` with an empty, a seeded and a stale (closed id on top)
history file, and `printf '\n' | script.sh` for the empty-input path. Test the daemon
against a fake socket that answers `events.subscribe` with `subscription_started`, streams a
few `*_focused`/`tab_created`/`tab_renamed` lines and closes: check the history files, the
`tab rename` calls (only labels lacking the suffix) and that a second start exits on the
lock. To eyeball colours run under `script -qec "printf '\n' | ./manage-tabs.sh" /dev/null`
(a pty). To time the list phase, `sleep() { :; }; export -f sleep` neutralises the fail sleeps;
interleave jq/python samples because machine load swings the numbers. **Never time or run
`manage-panes.sh --toggle` with the real `HERDR_SOCKET_PATH` in the environment**: pane focus
goes straight to the socket, not through the `herdr` CLI, so a CLI stub does not catch it.
