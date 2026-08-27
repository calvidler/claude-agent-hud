# Claude Agent HUD

A small always-on-top panel for macOS that shows what each of your Claude Code
sessions is doing: working, waiting for you, idle, or dead, and for how long.
Click a row to jump to that terminal.

<!-- ![Claude Agent HUD panel](docs/screenshot.png) -->

## Install

Needs macOS 14+, Claude Code, and the Xcode Command Line Tools.

```bash
git clone https://github.com/calvidler/claude-agent-hud.git
cd claude-agent-hud
./build.sh --install
```

That builds the app, puts it in `/Applications`, and opens it. Update with
`git pull && ./build.sh --install`. Without `--install` it runs from the repo
folder instead.

The first time you click a row, macOS asks to let the app control Terminal.
Allow it: that is what jump, clear, and compact use.

## Use

- **Click a row** to jump to that session's Terminal tab. ⌥⌘A shows or hides
  the panel.
- **Right-click a row** to rename it, auto-name it, clear or compact its
  context, open a new terminal in its folder, or copy its path or session ID.
- **Right-click the menu bar icon** (or the Dock icon) for Auto-name all,
  Clear all, and Settings.
- **Settings** turn on extra details per row (last prompt, model, context %),
  notifications (waiting, finished, high context), account usage limits, and
  switch between overlay, window, and menu bar dropdown.

Auto-name looks at your recent prompts and edited files and makes one small
Haiku call on your Claude Code login to pick a name. It can also rename a
session on its own after a chosen number of new prompts.

### Open it when Claude Code starts

Optional. Add this to `~/.claude/settings.json` and a dialog offers to open
the HUD whenever a session starts while it is not running:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/agent-hud/hooks/session-start.sh" } ] }
    ]
  }
}
```

Change the path if you cloned somewhere else.

## Privacy

One Swift file, no dependencies, no telemetry. It reads `claude agents --json`
and your local transcripts in `~/.claude/`. The only network calls are the
ones you trigger: auto-name (a Haiku call through Claude Code) and, if you turn
on usage limits, Anthropic's usage endpoint using your Claude Code login token.

## Limitations

- Tab selection, clear, and compact work with Terminal.app only; other
  terminals are just brought to the front.
- Timers start when the HUD first sees a state; restarting the HUD resets them.
- Context % updates after each completed reply, not live.
- A renamed session's own prompt bar shows the old name until it restarts.
- Anthropic's usage endpoint rate-limits hard (HTTP 429). The HUD keeps the
  last numbers, backs off, and shows when it will retry.

## Uninstall

Quit the app, delete `Claude Agent HUD.app` from `/Applications` and the repo
folder. Optional: `~/Library/Preferences/app.claude-agent-hud.plist` and
`~/Library/Caches/app.claude-agent-hud/`.
