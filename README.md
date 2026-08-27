# Claude Agent HUD

A small macOS overlay that shows what your Claude Code sessions are doing.

Run several Claude Code agents in different terminal tabs and you lose track of
which one is working, which one stopped to ask you something, and which one
finished twenty minutes ago. Claude Agent HUD is a tiny always-on-top panel that
answers that at a glance:

- a dot per session: green working, orange waiting for you, grey idle
- how long each has been working, or how long it has been idle
- click a row to jump straight to that session's terminal tab
- optional extras per row: last prompt, model, context % with a /compact warning
- expandable rows listing the subagents a session has spawned
- macOS notifications when a session is waiting on you, finishes, or is
  running out of context

It is a single Swift file with no dependencies. It reads only local Claude Code
data and needs no credentials for its core features.

<!-- screenshot: ![Claude Agent HUD panel](docs/screenshot.png) -->

## Requirements

- macOS 14 or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
  (the app finds `claude` in the usual Homebrew, npm, and local install paths)
- Xcode or the Xcode Command Line Tools, to build it

## Install

```bash
git clone https://github.com/calvidler/claude-agent-hud.git
cd claude-agent-hud
./build.sh
```

That compiles `Claude Agent HUD.app` in the repo folder, signs it locally, and
launches it. The panel appears top-right and a sparkles icon appears in the
menu bar. Move `Claude Agent HUD.app` to `/Applications` if you like; nothing
depends on where it lives.

To update, `git pull` and run `./build.sh` again.

## Using it

| Action | How |
|---|---|
| Show or hide the panel | Click the menu bar icon, or press ⌥⌘A anywhere |
| Move the panel | Drag it |
| Jump to a session's terminal | Click its row |
| More actions for a session | Right-click its row: reveal folder, copy path or session ID, show subagents, hide from list |
| See a session's subagents | Click the chevron on its row |
| Open settings | The gear in the panel's top bar, or right-click the menu bar icon |
| Quit | Right-click the menu bar icon |

Sessions that sit idle past a threshold (default 6 hours) are marked dead and
get an × to clear them from the list. They come back automatically if they
start working again.

## Settings

- **General**: display mode (always-on-top overlay, a normal window that can
  go behind others, or a menu bar dropdown), Dock icon, row order, dead timer.
- **Details**: what each row shows beyond name and state: last prompt, model,
  context % and its warning threshold, and the account usage footer.
- **Appearance**: background and text colour and opacity.
- **Notifications**: notify when a session is waiting for input, has finished,
  or has crossed the context threshold.

Settings persist between launches.

## What it reads

Everything is local unless you opt in to the last item:

- `claude agents --json`, Claude Code's own session list, polled every 4 seconds
- the tail of each session's transcript in `~/.claude/projects/`, for the last
  typed prompt, context tokens, model, and subagent activity
- `~/.claude/settings.json`, to infer the context window size from your default
  model
- **Opt-in, off by default**: the "Usage left" setting reads your Claude Code
  sign-in token from the macOS Keychain and asks Anthropic's usage endpoint for
  your rate-limit status, once a minute. The token is sent nowhere except
  `api.anthropic.com`. Leave it off and the app never touches the Keychain.

No analytics, no telemetry, no network access beyond that one optional call.

## Limitations

- Jumping to the exact terminal tab works with Terminal.app. Other terminals
  (iTerm2, Ghostty, VS Code) are brought to the front but the tab is not
  selected.
- Working and idle timers start when the app first sees the state, because
  Claude Code only reports the current status. Restarting the app restarts the
  timers.
- Context % is read from the last completed reply, so it updates per turn
  rather than live.
- Notifications are sent through AppleScript, so macOS attributes them to
  Script Editor in Notification Centre. If none appear, check that Script
  Editor is allowed to notify in System Settings.

## Development

The whole app is `agent-hud.swift`. `build.sh` compiles it into the bundle
using `Info.plist` and `AppIcon.icns` (regenerate the icon with
`swift make-icon.swift out.png`, then `sips` and `iconutil`). Preferences are
stored at `~/Library/Preferences/app.claude-agent-hud.plist`.

## Uninstall

Quit the app, delete `Claude Agent HUD.app` and the repo folder, and optionally
remove `~/Library/Preferences/app.claude-agent-hud.plist`.
