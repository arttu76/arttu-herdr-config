#!/usr/bin/env bash
# Human-readable `herdr agent list`. Usage: herdr-agents.sh [--machine <label>]
herdr "$@" agent list | python3 -I -c '
import json, sys
agents = json.load(sys.stdin)["result"]["agents"]
if not agents:
    print("no agents"); sys.exit()
home = __import__("os").path.expanduser("~")
rows = [("PANE", "AGENT", "STATUS", "CWD", "TITLE")]
for a in agents:
    cwd = a.get("cwd", "").replace(home, "~", 1)
    title = a.get("terminal_title_stripped") or a.get("terminal_title") or ""
    pane = a["pane_id"] + ("*" if a.get("focused") else "")
    rows.append((pane, a.get("agent", "?"), a.get("agent_status", "?"), cwd, title))
w = [max(len(r[i]) for r in rows) for i in range(4)]
for r in rows:
    print("  ".join(c.ljust(w[i]) for i, c in enumerate(r[:4])) + "  " + r[4])
'
