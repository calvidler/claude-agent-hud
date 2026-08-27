#!/bin/bash
# Builds Agent HUD.app from agent-hud.swift and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

APP="Agent HUD.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -o "$APP/Contents/MacOS/agent-hud" agent-hud.swift
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null || true

pkill -f "$APP/Contents/MacOS/agent-hud" 2>/dev/null || pkill -x agent-hud 2>/dev/null || true
sleep 1
open "$APP"
echo "built and launched $APP"
