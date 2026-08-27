import Foundation

/// Works out which session is running in Terminal.app's selected tab, by
/// matching ttys. Serialises its shell-outs on one queue and caches each pid's
/// tty, which never changes for the life of the process.
final class TerminalFocusTracker {
    private let queue = DispatchQueue(label: "app.claude-agent-hud.focus", qos: .utility)
    private var ttyByPid: [Int: String] = [:]

    /// Answers on the main queue.
    func selectedPid(among sessions: [AgentSession], completion: @escaping (Int?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let pid = self.lookup(sessions)
            DispatchQueue.main.async { completion(pid) }
        }
    }

    private func lookup(_ sessions: [AgentSession]) -> Int? {
        let tty = Shell.run(
            "/usr/bin/osascript",
            ["-e", "tell application \"Terminal\" to tty of selected tab of front window"]
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tty.hasPrefix("/dev/") else { return nil }
        for session in sessions where ttyByPid[session.pid] == nil {
            let raw = Shell.run("/bin/ps", ["-o", "tty=", "-p", "\(session.pid)"]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ttyByPid[session.pid] = raw.isEmpty || raw == "??" ? "" : "/dev/\(raw)"
        }
        let livePids = Set(sessions.map(\.pid))
        ttyByPid = ttyByPid.filter { livePids.contains($0.key) }
        return sessions.first { ttyByPid[$0.pid] == tty }?.pid
    }
}
