#!/bin/bash
# Claude Code SessionStart hook: if Claude Agent HUD isn't running, offer to
# open it. The dialog runs in the background so the session starts immediately.
pgrep -x agent-hud >/dev/null && exit 0

APP="/Applications/Claude Agent HUD.app"
[[ -d "$APP" ]] || APP="$(cd "$(dirname "$0")/.." && pwd)/Claude Agent HUD.app"
[[ -d "$APP" ]] || exit 0

(
  answer=$(osascript -e 'display dialog "Claude Agent HUD is not running. Open it?" buttons {"Not now", "Open"} default button "Open" with title "Claude Agent HUD" giving up after 20' 2>/dev/null)
  [[ "$answer" == *"Open"* && "$answer" != *"gave up:true"* ]] && open -g "$APP"
) &
exit 0
