# herdr setup

Portable [herdr](https://herdr.dev) configuration, shared between machines through this git
repository. The real files live in the clone at `~/arttu-herdr-config`; the home directory
only holds symlinks, so a script edit is live on this machine at once and on the others after
`git pull`. Works on Linux and macOS.

## Install on a new machine

herdr itself must already be installed (`install.sh` exits if it is not).

```sh
git clone https://github.com/arttu76/arttu-herdr-config.git ~/arttu-herdr-config
~/arttu-herdr-config/install.sh
```

The clone must live at `~/arttu-herdr-config`: `config.toml` refers to the scripts as
`$HOME/arttu-herdr-config/...` and `install.sh` fails anywhere else.

`install.sh` is idempotent. Rerun it after `herdr update` (to refresh the skill) or after
`git pull`. It:

1. checks the prerequisites (bash >= 4 and python3 >= 3.12 on PATH),
2. symlinks `~/.config/herdr/config.toml` here (an existing plain file is moved to `.bak.*`),
3. regenerates `skills/herdr/SKILL.md` from the installed binary and symlinks it
   into `~/.claude/skills/herdr` so Claude Code can drive herdr,
4. installs the Claude Code hook that reports agent state to the herdr sidebar,
5. installs (or re-enables) the plugins listed in `PLUGINS` in step 4 of the script, and fails
   when a `plugin_action` key in `config.toml` refers to a plugin missing from that list,
6. validates the config and reloads the running server.

Config edits need `herdr config check` and then `herdr server reload-config` (install.sh does
both). Script edits need nothing: herdr reads the scripts on every keypress.

### macOS

```sh
brew install bash jq fzf
```

`/bin/bash` on macOS is 3.2 and lacks `mapfile`, so the scripts use `#!/usr/bin/env bash`
and need the Homebrew bash first on PATH. `setsid` does not exist on macOS, so
`herdr-pane-info.sh` starts the focus tracker through python there, and the tracker's lock is
python `fcntl.flock` on both platforms. The clock entry in the tab bar is Linux only on purpose.

## Plugins

| Plugin | Source | Key |
|--------|--------|-----|
| `persiyanov.reviewr` | [persiyanov/herdr-reviewr](https://github.com/persiyanov/herdr-reviewr): agent diff review with line comments sent back to the agent | `prefix+d` |

To add a plugin, add it to `PLUGINS` in `install.sh`, bind its action in `config.toml`
(`type = "plugin_action"`, `command = "<plugin id>.<action id>"`) and add a row here.
Plugins run unsandboxed as your user, so read the manifest and build script first.
`herdr plugin update` updates them; `install.sh` only installs missing ones.

Requires `python3` (3.12+: `tomllib` and nested f-string quotes) and, for the pickers, `fzf` (falls back to a numbered list). `jq` is
optional but makes the prefix+p/t/w/a toggles about twice as fast (python startup is the
bottleneck, especially when agents load the machine); without it the toggles use python.

## Files

| File | Purpose |
|------|---------|
| `config.toml` | herdr config: theme, borders, keys, popups, sidebar rows, status line |
| `install.sh` | sets up symlinks, skill and hook on this machine |
| `herdr-pane-info.sh` | status line text for the tab bar: path, git branch, status, remote, hashes |
| `manage-lib.sh` | shared core of the four `manage-*.sh` popups: colours, prompt grammar, list display, focus history, dispatch and the `jq` fast path for `--toggle`. Sourced, not run |
| `manage-agents.sh` | popup: lists agents, one prompt. `<n>question` asks agent #n without changing focus, `r<n>name` renames it (`-` clears, spaces become `-`, lowercased) and focuses it, empty input toggles focus to the last agent (from an agent pane: the previous agent); `--toggle` does only that, no popup |
| `manage-panes.sh` | popup: lists panes from all workspaces, one prompt. `<n>` switches to pane #n (across workspaces), `n [name]` splits the focused pane (right if wide, down if tall), `r<n>name` renames it (`-` clears) and switches to it, `D<n>` closes it, empty input toggles to the previously focused pane; `--toggle` does only that, no popup |
| `manage-tabs.sh` | popup: lists tabs from all workspaces, one prompt. `<n>` switches to tab #n (across workspaces), `n [name]` creates a tab in the current workspace, `r<n>name` renames it and switches to it, `D<n>` closes it, empty input toggles to the previously focused tab; `--toggle` does only that, no popup. Labels get the tab's position in the workspace as a suffix, `name(2)`, because `prefix+2` switches to the 2nd tab |
| `manage-workspaces.sh` | popup: lists workspaces, one prompt. `<n>` switches to workspace #n, `n [name]` creates one, `r<n>name` renames it and switches to it, `D<n>` closes it, empty input toggles to the previously focused workspace; `--toggle` does only that, no popup |
| `herdr-focus-track.sh` | daemon: subscribes to Herdr's focus events on the socket and writes the focus history (`~/.local/state/herdr/*-focus`) that the toggles use; also keeps tab labels suffixed with their position in the workspace. `herdr-pane-info.sh` (re)starts it on every tab bar refresh when the pid in `focus-track.pid` is dead; a `flock(2)` lock on `focus-track.lock`, taken in python, keeps one instance |
| `herdr-agents.sh` | human-readable `herdr agent list` for the shell |
| `skills/herdr/SKILL.md` | Claude Code skill, generated by `herdr --skill` on install; gitignored because it is derived from the local binary |
| `.gitignore` | the generated skill and `.DS_Store` |

Herdr runs every `command = ...` string through `/bin/sh -c`, so `config.toml` refers to
the scripts as `$HOME/arttu-herdr-config/<script>` and the same file works for any user and
on both Linux and macOS. `~` is not expanded by `sh -c` inside a double-quoted TOML string, so
the config uses `$HOME`.

## Layout model

`session > workspace > tab > pane`. A tab is the tmux window. A workspace (the
sidebar calls it a Space) groups tabs, usually one per project or worktree.

## Keys (prefix is ctrl+b)

Custom bindings, tmux-flavoured:

| Key | Action |
|-----|--------|
| `prefix+"` | split stacked (top/bottom) |
| `prefix+%` | split side by side |
| `prefix+t` | previous tab: toggle between the current and the previously focused tab, across workspaces |
| `prefix+T` | manage tabs: switch by number across workspaces, `n [name]` new tab, `r<n>` rename (and switch to it), `D<n>` close, enter alone = same toggle (popup) |
| `prefix+/` | go to: session navigator |
| `prefix+p` | previous pane: toggle between the current and the previously focused pane, across workspaces |
| `prefix+P` | manage panes: switch by number across workspaces, `n [name]` new pane, `r<n>` rename (and switch to it), `D<n>` close, enter alone = same toggle (popup) |
| `prefix+w` | previous workspace: toggle between the current and the previously focused workspace |
| `prefix+W` | manage workspaces: switch by number, `n [name]` new workspace, `r<n>` rename (and switch to it), `D<n>` close, enter alone = same toggle (popup) |
| `prefix+a` | previous agent: toggle to the last focused agent (from an agent pane: the previous one) |
| `prefix+A` | manage agents: ask by number, rename with `r<n>` (and focus it), enter alone = same toggle (popup) |

The lowercase keys use a focus history, not Herdr's list-order cycling: the popups record
what they focus and the `herdr-focus-track.sh` daemon records every other focus change the
moment Herdr emits the event.
Popup lists highlight the current item (`▶`, bright cyan), colour agent status (green =
working, yellow = blocked) and show close/errors in red; set `NO_COLOR=1` to disable.
| `prefix+d` | toggle the reviewr plugin pane (diff review beside the agent) |

Useful herdr defaults left as they are: `prefix+c` new tab, `prefix+n` next tab, `prefix+1..9` switch tab, `prefix+h/j/k/l` focus pane, `prefix+x` close pane,
`prefix+z` zoom, `prefix+[` copy mode, `prefix+b` toggle sidebar, `prefix+?` help.
`prefix+prefix` sends a literal ctrl+b to the pane and cannot be rebound.

## Appearance

* Thin dividers between split panes only, no outer frame, no gaps. The focused
  pane's divider uses the theme accent colour.
* Tab bar at the bottom with the status line from `herdr-pane-info.sh`, then a clock (Linux only).
* Agent sidebar rows: state + workspace + tab, then agent kind + pane name, then
  the agent's own terminal title dimmed.
* No option exists yet to tint or dim unfocused panes (herdr 0.9.5). Tracked in
  herdr discussions #544 and #2891.

## Agents from the CLI

```sh
herdr-agents.sh                              # list agents
herdr agent rename w1:p2 reviewer            # name an agent
herdr agent prompt reviewer "run the tests"  # send it a prompt
herdr agent prompt reviewer "..." --wait     # and wait for it to finish
```

Agent names must match `[a-z][a-z0-9_-]{0,31}` and are cleared when the agent exits.

## Shell integration

Each pane gets a border label with path and git status on every prompt. The install script
does not touch your shell rc. bash, in `~/.bashrc`:

```bash
herdr_pane_label() {
    [ "${HERDR_ENV:-}" = 1 ] && [ -n "$HERDR_PANE_ID" ] || return 0
    ( herdr pane rename "$HERDR_PANE_ID" "$(~/arttu-herdr-config/herdr-pane-info.sh --short "$PWD")" >/dev/null 2>&1 & )
}
PROMPT_COMMAND="herdr_pane_label${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

zsh, in `~/.zshrc`:

```zsh
herdr_pane_label() {
    [[ "${HERDR_ENV:-}" = 1 && -n "$HERDR_PANE_ID" ]] || return 0
    ( herdr pane rename "$HERDR_PANE_ID" "$(~/arttu-herdr-config/herdr-pane-info.sh --short "$PWD")" >/dev/null 2>&1 & )
}
autoload -Uz add-zsh-hook && add-zsh-hook precmd herdr_pane_label
```
