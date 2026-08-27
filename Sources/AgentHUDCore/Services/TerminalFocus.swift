import AppKit
import Foundation

// MARK: - Terminal focus

/// Jumps to the terminal a session lives in: finds the session's tty and the
/// nearest ancestor GUI app, selects the matching Terminal.app tab, and
/// activates the app. Other terminals still get activated, just without tab
/// selection.
enum TerminalFocus {
    static func focus(pid: Int) {
        focus(pid: pid, thenType: nil)
    }

    /// Types a line into the session's terminal tab, as if entered at its prompt.
    /// Terminal.app only; other terminals are just brought to the front.
    static func clearContext(pid: Int) {
        focus(pid: pid, thenType: "/clear")
    }

    static func compactContext(pid: Int) {
        focus(pid: pid, thenType: "/compact")
    }

    /// Types /clear into every session's Terminal.app tab in one pass, without
    /// selecting or raising anything. Sessions in other terminals are skipped.
    static func clearContext(pids: [Int]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ttys = pids.compactMap { pid -> String? in
                let tty = Shell.run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]).output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tty.isEmpty, tty != "??",
                      ancestorApp(of: pid_t(pid))?.bundleIdentifier == "com.apple.Terminal" else { return nil }
                return "/dev/\(tty)"
            }
            guard !ttys.isEmpty else { return }
            let list = ttys.map { "\"\($0)\"" }.joined(separator: ", ")
            let script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if {\(list)} contains (tty of t) then
                            do script "/clear" in t
                        end if
                    end repeat
                end repeat
            end tell
            """
            Shell.run("/usr/bin/osascript", ["-e", script])
        }
    }

    /// Modal name prompt; nil when cancelled or left empty.
    static func askForName(current: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Renames quietly, without touching the session's terminal."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == current ? nil : name
    }

    private static func focus(pid: Int, thenType command: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tty = Shell.run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let app = ancestorApp(of: pid_t(pid)), let bundleId = app.bundleIdentifier else { return }
            if bundleId == "com.apple.Terminal", !tty.isEmpty, tty != "??" {
                selectTerminalTab(tty: "/dev/\(tty)", thenType: command)
            }
            bringForward(app)
        }
    }

    /// Opens a new Terminal.app window at the session's folder and resumes the
    /// session there. Once Claude Code is up it appears in the HUD like any
    /// other running session.
    static func resume(_ session: PastSession, fork: Bool = false) {
        resume(cwd: session.cwd, sessionId: session.id, displayName: session.displayName, fork: fork)
    }

    /// With `fork`, the new terminal gets a copy of the conversation under its
    /// own session id (`--fork-session`); the original keeps going untouched.
    static func resume(cwd: String, sessionId: String, displayName: String, fork: Bool) {
        guard FileManager.default.fileExists(atPath: cwd) else {
            Notifier.post("Can't resume \(displayName): its folder \(cwd) no longer exists")
            return
        }
        var command = "cd \(shellQuoted(cwd)) && \(shellQuoted(ClaudeCLI.path)) --resume \(sessionId)"
        if fork { command += " --fork-session" }
        let script = "tell application \"Terminal\" to do script \"\(appleScriptQuoted(command))\""
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.run("/usr/bin/osascript", ["-e", script])
            guard let terminal = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.Terminal").first else { return }
            bringForward(terminal)
        }
    }

    /// Bring forward only the app's main window (the one a script just
    /// selected or created), not every window of the app. macOS only lets the
    /// active app hand activation over, so the HUD briefly activates itself
    /// (allowed, the user just clicked it), yields, and requests single-window
    /// activation. If that is still refused, fall back to an Apple Event, which
    /// raises all of the app's windows.
    private static func bringForward(_ app: NSRunningApplication) {
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.yieldActivation(to: app)
            let handedOver = app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !handedOver || !app.isActive, let bundleId = app.bundleIdentifier {
                    Shell.run("/usr/bin/osascript", ["-e", "tell application id \"\(bundleId)\" to activate"])
                }
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func ancestorApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<10 {
            let raw = Shell.run("/bin/ps", ["-o", "ppid=", "-p", "\(current)"]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ppid = pid_t(raw), ppid > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: ppid),
               app.activationPolicy == .regular {
                return app
            }
            current = ppid
        }
        return nil
    }

    private static func selectTerminalTab(tty: String, thenType command: String?) {
        // Type before raising the window: `set index` renumbers Terminal's windows,
        // which would make the tab reference `t` resolve to a different window.
        let typeLine = command.map { "                        do script \"\($0)\" in t" } ?? ""
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
        \(typeLine)
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        Shell.run("/usr/bin/osascript", ["-e", script])
    }
}
