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
- Auto-name sessions from your recent requests and edited files, one at a time,
  all at once, or automatically after a chosen number of new prompts, with a
  single cheap Haiku call on your Claude Code login
- Expandable rows showing a session's subagents and whether they are running
- Optional notifications when a session is waiting for input, has finished,
  or is running out of context
- Optional account usage footer (session and weekly limits), refreshed by hand
  or on a timer, with the last result kept across launches
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

This builds `Claude Agent HUD.app`, signs it locally, and launches it. Use
`./build.sh --install` to put it in `/Applications` instead, where Spotlight,
Launchpad, and the Dock can open it like any other app. The
first time you click a row, macOS asks whether the app may control Terminal;
that permission is what makes jump, clear, and compact work. Settings are
behind the gear in the panel or the menu bar icon's right-click menu.

To update: `git pull && ./build.sh`.

### Open it when Claude Code starts

`hooks/session-start.sh` is a Claude Code `SessionStart` hook: when a session
starts and the HUD is not running, it shows an "Open Claude Agent HUD?" dialog
(in the background, so the session is not held up). Add it to
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/agent-hud/hooks/session-start.sh" } ] }
    ]
  }
}
```

Adjust the path if you cloned the repo elsewhere.

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
| Keychain token and Anthropic's usage endpoint | Only if "Usage left" is on; by hand by default, or on a timer you choose | Rate-limit status; the token goes to `api.anthropic.com` and nowhere else |

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
- Notifications ask for permission the first time one is sent; if you decline,
  they fall back to AppleScript and Notification Centre attributes them to
  Script Editor.
- Anthropic's usage endpoint rate-limits aggressively and, once tripped, can
  keep answering 429 for a long time (a known Claude Code issue). On a 429 the
  HUD keeps the last numbers, backs off (15 min doubling to 2 h, or longer if
  the server asks), and shows when it will retry. Manual refresh still works
  but may prolong the limit.

## Development

Everything is in `agent-hud.swift`; `build.sh` builds and relaunches.
`make-icon.swift` renders the icon (`swift make-icon.swift icon.png`, then
`iconutil`). Preferences live at `~/Library/Preferences/app.claude-agent-hud.plist`.

## Uninstall

Quit the app, delete `Claude Agent HUD.app` and the repo folder, and
optionally `~/Library/Preferences/app.claude-agent-hud.plist` and
`~/Library/Caches/app.claude-agent-hud/`.
