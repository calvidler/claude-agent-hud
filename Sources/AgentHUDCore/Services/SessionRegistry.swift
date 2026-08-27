import Foundation

// MARK: - Session registry

/// Renames a session without touching its terminal: writes the name into
/// Claude Code's session registry (~/.claude/sessions/<pid>.json, which
/// `claude agents` reads) and appends it to the transcript so the resume
/// picker agrees. The live session's own prompt bar keeps its old name until
/// it restarts. HUD-set names are re-applied if the session reverts to an
/// auto-derived title; a name set with /rename is always respected.
enum SessionRegistry {
    private static var quietNames: [String: String] = [:]  // sessionId -> name, main thread only

    static func setName(_ name: String, for session: AgentSession) {
        DispatchQueue.main.async {
            quietNames[session.sessionId] = name
            write(name, pid: session.pid)
            appendToTranscript(name, transcript: session.transcript)
        }
    }

    /// A session that is not running has no registry entry; the transcript
    /// line is what the resume picker and the HUD's past-session list read.
    static func setName(_ name: String, forPast transcript: TranscriptRef) {
        appendToTranscript(name, transcript: transcript)
    }

    /// True when the user named this session themselves (via /rename), as
    /// opposed to Claude Code's derived title or a name the HUD set.
    static func isUserNamed(_ session: AgentSession) -> Bool {
        guard read(pid: session.pid)?["nameSource"] as? String == "custom" else { return false }
        return quietNames[session.sessionId] != session.name
    }

    static func reassert(_ sessions: [AgentSession]) {
        for session in sessions {
            guard let wanted = quietNames[session.sessionId], session.name != wanted else { continue }
            if read(pid: session.pid)?["nameSource"] as? String == "custom" {
                quietNames[session.sessionId] = nil  // renamed by the user; theirs wins
            } else {
                write(wanted, pid: session.pid)
            }
        }
    }

    private static func path(pid: Int) -> String {
        NSHomeDirectory() + "/.claude/sessions/\(pid).json"
    }

    private static func read(pid: Int) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path(pid: pid)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func write(_ name: String, pid: Int) {
        guard var registry = read(pid: pid) else { return }
        registry["name"] = name
        registry["nameSource"] = "custom"
        registry["nameSince"] = Int(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: registry) else { return }
        try? data.write(to: URL(fileURLWithPath: path(pid: pid)), options: .atomic)
    }

    private static func appendToTranscript(_ name: String, transcript: TranscriptRef) {
        let entry: [String: String] = ["type": "agent-name", "agentName": name, "sessionId": transcript.sessionId]
        guard let handle = FileHandle(forUpdatingAtPath: transcript.path),
              let line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        defer { try? handle.close() }
        // Never fuse with a final line that lacks its newline.
        var payload = Data()
        if let end = try? handle.seekToEnd(), end > 0 {
            try? handle.seek(toOffset: end - 1)
            if let last = try? handle.read(upToCount: 1), last != Data("\n".utf8) {
                payload.append(contentsOf: "\n".utf8)
            }
            _ = try? handle.seekToEnd()
        }
        payload.append(line)
        payload.append(contentsOf: "\n".utf8)
        handle.write(payload)
    }
}
