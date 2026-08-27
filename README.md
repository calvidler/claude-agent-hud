# Claude Agent HUD

A small always-on-top panel for macOS that shows what your Claude Code
sessions are doing, so you can run several agents at once without losing
track of them.

<!-- ![Claude Agent HUD panel](docs/screenshot.png) -->

## Features

- One row per session: state dot (working, waiting for you, idle, dead), name,
  and how long it has been in that state
- Optional per-row details: last prompt, model, context % with a warning
  threshold
- Click a row to jump to that session's Terminal tab; right-click to rename,
  auto-name, clear or compact context, open a terminal at its folder, or
  copy its path or session ID
- Auto-name sessions from your recent requests and edited files, one at a time
  or all at once, with a single cheap Haiku call on your Claude Code login
- Expandable rows showing a session's subagents and whether they are running
- Optional notifications when a session is waiting for input, has finished,
  or is running out of context
- Overlay, window, or menu bar dropdown; optional Dock icon; ⌥⌘A toggles the
  panel

## Install

Requires macOS 14 or later, [Claude Code](https://docs.anthropic.com/en/docs/claude-code),
and Xcode or the Xcode Command Line Tools.

```bash
git clone https://github.com/calvidler/claude-agent-hud.git
cd claude-agent-hud
./build.sh
```

This builds `Claude Agent HUD.app`, signs it locally, and launches it. The
first time you click a row, macOS asks whether the app may control Terminal;
that permission is what makes jump, clear, and compact work. Settings are
behind the gear in the panel or the menu bar icon's right-click menu.

To update: `git pull && ./build.sh`.

## What it reads, and what leaves your machine

Single Swift file, no dependencies, no credentials needed for the core
features.

| Source | When | Purpose |
|---|---|---|
| `claude agents --json` | Every 4 s | Session list and status |
| Transcript tails in `~/.claude/projects/` | Every 4 s | Last prompt, context tokens, model, subagents |
| `~/.claude/settings.json` | Every 4 s | Infers the context window size from your default model |
| `~/.claude/sessions/` and the transcript | When you rename | Writes the new name where Claude Code reads it |
| `claude -p --model haiku` | When you auto-name | One small call on your Claude Code login, no tools, no saved session, run in an empty folder |
| Keychain token and Anthropic's usage endpoint | Only if "Usage left" is on; every 10 min by default, or by hand | Rate-limit status; the token goes to `api.anthropic.com` and nowhere else |

No analytics, no telemetry. The only network activity is the two calls above,
one opt-in and one you trigger by hand.

## Limitations

- Tab selection and the clear/compact buttons work with Terminal.app; other
  terminals are only brought to the front.
- Timers start when the HUD first sees a state; restarting the HUD restarts
  them.
- Context % updates per completed reply, not live.
- A renamed session's own prompt bar keeps its old name until that session
  restarts. Renaming writes into Claude Code's session files; a format change
  in a future release would break renaming and nothing else.
- Notifications are sent via AppleScript, so Notification Centre attributes
  them to Script Editor.

## Development

Everything is in `agent-hud.swift`; `build.sh` builds and relaunches.
`make-icon.swift` renders the icon (`swift make-icon.swift icon.png`, then
`iconutil`). Preferences live at `~/Library/Preferences/app.claude-agent-hud.plist`.

## Uninstall

Quit the app, delete `Claude Agent HUD.app` and the repo folder, and
optionally `~/Library/Preferences/app.claude-agent-hud.plist` and
`~/Library/Caches/app.claude-agent-hud/`.
