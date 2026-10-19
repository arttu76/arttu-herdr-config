#!/usr/bin/env bash
# Set up herdr on this machine from this git clone (must live at ~/arttu-herdr-config).
# Idempotent: safe to rerun after `herdr update` or after `git pull`.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR="$HOME/.config/herdr"
SKILL_DIR="$HOME/.claude/skills"

command -v herdr >/dev/null || {
  echo "herdr not installed. Install with:  curl -fsSL https://herdr.dev/install.sh | sh" >&2
  exit 1
}

chmod +x "$SRC"/*.sh
mkdir -p "$CFG_DIR" "$SKILL_DIR"
command -v jq >/dev/null || echo "note: jq not found; the prefix+p/t/w/a toggles will use the slower python path"

# 0. Prerequisites. The scripts need bash >= 4 on PATH (macOS ships 3.2; brew install bash)
#    and python3 >= 3.12 (tomllib, nested f-string quotes).
bash -c '(( BASH_VERSINFO[0] >= 4 ))' || { echo "bash >= 4 required on PATH (macOS: brew install bash)" >&2; exit 1; }
python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 12))' || { echo "python3 >= 3.12 required" >&2; exit 1; }
command -v setsid >/dev/null || echo "note: setsid not found (normal on macOS); the focus tracker is started through python"

# 1. config.toml: a symlink, so edits here apply on every machine after `git pull`. The config
#    refers to the scripts as $HOME/arttu-herdr-config/... (herdr runs commands through
#    /bin/sh -c, which expands $HOME), so the clone must live exactly there.
[[ "$SRC" == "$HOME/arttu-herdr-config" || "$(cd "$HOME/arttu-herdr-config" 2>/dev/null && pwd -P)" == "$(pwd -P)" ]] || {
  echo "this clone is at $SRC but config.toml expects \$HOME/arttu-herdr-config; move or symlink it there" >&2
  exit 1
}
if [[ -e "$CFG_DIR/config.toml" && ! -L "$CFG_DIR/config.toml" ]]; then
  mv "$CFG_DIR/config.toml" "$CFG_DIR/config.toml.bak.$(date +%Y%m%d%H%M%S)"
  echo "config: existing $CFG_DIR/config.toml moved aside (.bak.*)"
fi
ln -sfn "$SRC/config.toml" "$CFG_DIR/config.toml"
echo "config: symlinked $CFG_DIR/config.toml -> $SRC/config.toml"

# 2. Claude Code skill (teaches Claude the herdr CLI). Regenerated from the binary so it
#    matches the installed version; the file is gitignored because it is derived, per machine.
herdr --skill > "$SRC/skills/herdr/SKILL.md"
rm -rf "$SKILL_DIR/herdr"
ln -sfn "$SRC/skills/herdr" "$SKILL_DIR/herdr"
echo "skill:  $SKILL_DIR/herdr -> $SRC/skills/herdr"

# 3. Claude Code hook that reports agent state to the herdr sidebar.
herdr integration install claude >/dev/null && echo "integration: claude hook installed/updated"

# 4. Plugins: "<plugin id>  <source for herdr plugin install>". Every plugin that a
#    type = "plugin_action" key in config.toml refers to must be listed here, else this fails.
PLUGINS="
persiyanov.reviewr  persiyanov/herdr-reviewr
"
referenced=$(python3 -I - "$SRC/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    keys = tomllib.load(f).get("keys", {}).get("command", [])
# A plugin action is "<plugin id>.<action id>"; plugin ids may contain dots, action ids not.
for pid in sorted({k["command"].rsplit(".", 1)[0] for k in keys if k.get("type") == "plugin_action"}):
    print(pid)
PY
)
for id in $referenced; do
  [[ -n $(awk -v id="$id" '$1 == id' <<<"$PLUGINS") ]] || {
    echo "config.toml uses plugin $id: add it to PLUGINS in install.sh" >&2
    exit 1
  }
done
installed=$(herdr plugin list --json | python3 -I -c 'import json, sys
for p in json.load(sys.stdin)["result"]["plugins"]:
    print(p["plugin_id"], "enabled" if p["enabled"] else "disabled")')
while read -r id source; do
  [[ -z $id ]] && continue
  case $(awk -v id="$id" '$1 == id {print $2}' <<<"$installed") in
    enabled)  echo "plugin: $id already installed" ;;
    disabled) herdr plugin enable "$id" </dev/null >/dev/null && echo "plugin: $id enabled" ;;
    *)        herdr plugin install "$source" --yes </dev/null >/dev/null && echo "plugin: $id installed from $source" ;;
  esac
done <<<"$PLUGINS"

# 5. Validate and apply.
herdr config check
# `herdr status server` exits 0 even when no server runs, so inspect the reload result instead.
out=$(herdr server reload-config 2>&1) || true
if ! grep -q '"error"' <<<"$out"; then echo "server: config reloaded"
elif grep -q server_not_running <<<"$out"; then echo "server: not running, config applies on next start"
else echo "$out" >&2; exit 1
fi
