# Claude Agent HUD

A small macOS overlay that shows the state of local Claude Code sessions: what
each agent is doing, how long it has been working, whether it is waiting for
input, and how full its context is.

Built as a single-file SwiftUI app, custom for this machine.

## Features

- Floating panel listing every Claude Code session with a status dot
  (green working, orange waiting, grey idle, dark red dead), working/idle
  timers, and optional last prompt, model, and context %
- Three display modes: always-on-top overlay, normal window, or menu bar
  dropdown; optional Dock icon
- Click a row to jump to that session's Terminal tab
- Expandable rows showing recent subagents and whether they are still running
- Dead timer: sessions idle past a threshold are marked dead and can be
  cleared from the list
- Context warnings: badge turns orange past a threshold, with an optional
  macOS notification suggesting /compact; optional notification when a
  session is waiting for input
- Optional account usage footer (5h / weekly limits)
- Menu bar icon with busy count, and `N!` when sessions need input
- Colours, opacity, row order, name, and all toggles in a Settings window;
  preferences persist and survive new settings being added

## Data sources

All local, except the last one, which is opt-in:

- `claude agents --json`: session list and status, polled every 4s
- Transcript tails under `~/.claude/projects/`: last typed prompt, context
  tokens, model, subagent activity
- `~/.claude/settings.json`: default model, to infer the context window size
- Anthropic's usage endpoint, using the Claude Code OAuth token from the
  Keychain: only while "Show usage left" is on, polled every 60s, token sent
  nowhere except api.anthropic.com

## Build

```
./build.sh
```

Compiles `agent-hud.swift` into `Claude Agent HUD.app`, ad-hoc signs it, and
relaunches it. Requires Xcode (Swift 5.9+) and macOS 14+.

## Files

- `agent-hud.swift`: the entire app
- `build.sh`: build + relaunch
- `Info.plist`: bundle metadata
- `AppIcon.icns`: Dock icon (regenerate with `swift make-icon.swift out.png`,
  then `sips`/`iconutil`)
- Preferences live at `~/Library/Preferences/com.callum.agent-hud.plist`
