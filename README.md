# Claude Agent HUD

A small always-on-top panel for macOS that shows what your Claude Code
sessions are doing, so you can run several agents at once without losing
track of them.

<!-- ![Claude Agent HUD panel](docs/screenshot.png) -->

Running three or four Claude Code agents in different terminal tabs works
well right up until you forget which one stopped to ask you a question twenty
minutes ago. Claude Agent HUD answers that at a glance, from a panel that
floats over whatever you are doing.

## What it shows

Each session gets one row:

- **State dot**: green working, orange waiting for you, grey idle, dark red
  dead (idle past a threshold you choose)
- **Name**: the session's Claude Code name, so `/rename` and the HUD agree
- **Timer**: how long it has been working, or how long it has been idle
- **Optional details**: the last thing you typed, the model in use, and
  context usage as a percentage that turns orange past a warning threshold

Rows expand to list the subagents a session has spawned and whether each is
still running.

## What it does

- **Jump to a session**: click its row to select that exact Terminal tab and
  bring only that window forward
- **Act on a session**: right-click for rename, auto-name, clear or compact
  context, open a new terminal at its folder, reveal the folder in Finder,
  copy its path or session ID
- **Auto-name**: names a session from your recent requests and the files it
  edited, with a single cheap Haiku call on your Claude Code login. Name one
  session from its row, or every session from the menu bar
- **One-click hygiene**: dead sessions get an eraser that sends `/clear`;
  idle sessions past the context threshold get a compact button that sends
  `/compact`
- **Notifications**: optional macOS banners when a session is waiting for
  input, has finished, or is running out of context. Each fires once per
  episode, never repeatedly
- **Three display modes**: always-on-top overlay, a normal window that can go
  behind others, or a menu bar dropdown. Optional Dock icon
- **Global hotkey**: ⌥⌘A shows or hides the panel from anywhere

## Install

Requirements: macOS 14 or later, [Claude Code](https://docs.anthropic.com/en/docs/claude-code),
and Xcode or the Xcode Command Line Tools.

```bash
git clone https://github.com/calvidler/claude-agent-hud.git
cd claude-agent-hud
./build.sh
```

`build.sh` compiles the app, signs it locally, and launches it. The panel
appears at the top right and a sparkles icon appears in the menu bar. Move
`Claude Agent HUD.app` to `/Applications` if you like; nothing depends on
where it lives.

To update: `git pull && ./build.sh`.

## Using it

| Action | How |
|---|---|
| Show or hide the panel | Click the menu bar icon, or press ⌥⌘A |
| Move the panel | Drag it |
| Jump to a session's terminal | Click its row |
| Session actions | Right-click its row |
| Name every session at once | Right-click the menu bar icon or Dock icon, then Auto-name all |
| See a session's subagents | Click the chevron on its row |
| Open settings | The gear in the panel's top bar, or right-click the menu bar icon |
| Quit | Right-click the menu bar icon |

The first time you click a row, macOS asks whether the HUD may control
Terminal. That permission is what makes jump, clear, and compact work.

## Settings

Four tabs, all changes applied live and remembered between launches:

- **General**: display mode, Dock icon, row order, dead timer
- **Details**: which extras each row shows (last prompt, model, context %) and
  the context warning threshold; the account usage footer
- **Appearance**: background and text colour and opacity
- **Notifications**: waiting for input, finished working, high context

## What it reads, and what leaves your machine

The app is a single Swift file with no dependencies, and its core features
need no credentials. In full:

| Source | When | Purpose |
|---|---|---|
| `claude agents --json` | Every 4 s | Session list and status |
| Transcript tails in `~/.claude/projects/` | Every 4 s | Last prompt, context tokens, model, subagents |
| `~/.claude/settings.json` | Every 4 s | Infers the context window size from your default model |
| `~/.claude/sessions/` and the transcript | When you rename | Writes the new name where Claude Code reads it |
| `claude -p --model haiku` | When you auto-name | One small call on your Claude Code login, no tools, no saved session, run in an empty folder |
| Keychain token and Anthropic's usage endpoint | Only if "Usage left" is on, every 60 s | Rate-limit status; the token goes to `api.anthropic.com` and nowhere else |

Nothing else is read. No analytics, no telemetry. The only network activity
is the two calls above, one opt-in and one you trigger by hand.

## Limitations

- Exact-tab selection and the clear/compact buttons work with Terminal.app.
  Other terminals are brought to the front without tab selection.
- Working and idle timers start when the HUD first sees a state, because
  Claude Code only reports the current status. Restarting the HUD restarts
  them.
- Context percentage comes from the last completed reply, so it updates per
  turn rather than live.
- A renamed session's own prompt bar keeps its old name until that session
  restarts; the HUD, `claude agents`, and the resume picker show the new one.
- Renaming writes into Claude Code's own session files. If a future Claude
  Code release changes that format, renaming stops working; nothing else is
  affected.
- Notifications are sent through AppleScript, so Notification Centre
  attributes them to Script Editor. If none appear, allow notifications for
  Script Editor in System Settings.

## Development

Everything is in `agent-hud.swift`. `build.sh` compiles it into the bundle
using `Info.plist` and `AppIcon.icns`. To regenerate the icon:

```bash
swift make-icon.swift icon.png
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset
```

Preferences are stored at `~/Library/Preferences/app.claude-agent-hud.plist`.

## Uninstall

Quit the app, delete `Claude Agent HUD.app` and the repo folder, and
optionally remove `~/Library/Preferences/app.claude-agent-hud.plist` and
`~/Library/Caches/app.claude-agent-hud/`.
