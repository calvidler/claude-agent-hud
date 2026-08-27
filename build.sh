#!/bin/bash
# Builds Claude Agent HUD.app from the Swift package and relaunches it.
# With --install, copies the app to /Applications and launches from there,
# so Spotlight, Launchpad, and the Dock can open it like any other app.
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Agent HUD.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift build -c release
cp .build/release/agent-hud "$APP/Contents/MacOS/agent-hud"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null || true
# Refresh LaunchServices so Notification Centre and the Dock pick up the current icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

pkill -x agent-hud 2>/dev/null || true
sleep 1

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "installed and launched /Applications/$APP"
else
  open "$APP"
  echo "built and launched $APP"
fi
