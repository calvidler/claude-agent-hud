# Claude Agent HUD

A small always-on-top panel for macOS that shows what each of your Claude Code
sessions is doing (editing a file, running a command, waiting for you, idle)
and for how long.
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

- **Click a row** to jump to that session's Terminal tab. A blue dot marks
  the session in Terminal's front tab. ⌥⌘A shows or hides the panel.
- **Right-click a row** to rename it, auto-name it, clear or compact its
  context, fork it (a new Terminal window continuing the same conversation
  under its own session ID), open a new terminal in its folder, or copy its
  path or session ID.
- **Needs you** (the hand in the top bar) puts sessions waiting on you first
  and dims the rest.
- **Click the menu bar icon** (or right-click the Dock icon) for Past
  sessions, Auto-name all, Settings, and Clear all at the top.
- **Past sessions** (the clock in the panel's top bar, or the menu) lists your
  40 most recent finished sessions, newest first. Click one to resume it in a
  new Terminal window; right-click to fork or auto-name it.
- **Settings** turn on extra details per row (last prompt, model, permission
  mode such as plan or auto, effort level, context %),
  notifications (waiting, finished, high context), account usage limits, and
  switch between overlay, window, and menu bar dropdown.
- **Skill library** (off by default, Settings > General) adds an "Add skill"
  submenu to a row's right-click menu that copies a skill into that project's
  `.claude/skills`. It starts with `/verify`, `/interview`, `/grill`,
  `/fresh-review`, and `/handoff`; add your own as folders holding a
  `SKILL.md` in `~/Library/Application Support/Claude Agent HUD/skills`.

Auto-name looks at your recent prompts and edited files and makes one small
Haiku call on your Claude Code login to pick a name. It can also rename a
session on its own after a chosen number of new prompts; with that on, a
session you clear or compact (from the HUD or by typing the command) is
marked `<folder>-cleared` or `<folder>-compacted` and named properly again
at its next prompt.

## Privacy

No dependencies, no telemetry. It reads `claude agents --json`
and your local transcripts in `~/.claude/`. The only network calls are the
ones you trigger: auto-name (a Haiku call through Claude Code) and, if you turn
on usage limits, Anthropic's usage endpoint using your Claude Code login token.
