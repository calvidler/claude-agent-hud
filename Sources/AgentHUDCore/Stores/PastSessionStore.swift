import Combine
import Foundation

// MARK: - Past sessions

/// Sessions that are no longer running, read from the transcripts Claude Code
/// leaves in ~/.claude/projects. Newest first, capped, local reads only.
final class PastSessionStore: ObservableObject {
    static let limit = 40
    @Published var sessions: [PastSession] = []
    @Published var loading = false
    private let queue = DispatchQueue(label: "agent-hud.past-sessions", qos: .userInitiated)

    func reload(excluding running: Set<String>) {
        loading = true
        queue.async {
            let found = Self.scan(excluding: running)
            DispatchQueue.main.async {
                self.sessions = found
                self.loading = false
            }
        }
    }

    func setName(_ name: String, for id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].name = name
    }

    func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
    }

    private static func scan(excluding running: Set<String>) -> [PastSession] {
        let root = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        var candidates: [(path: String, id: String, modified: Date)] = []
        for project in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + project
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".jsonl") {
                let id = String(file.dropLast(6))
                guard !running.contains(id),
                      let modified = (try? fm.attributesOfItem(atPath: dir + "/" + file))?[.modificationDate] as? Date
                else { continue }
                candidates.append((dir + "/" + file, id, modified))
            }
        }
        candidates.sort { $0.modified > $1.modified }
        var found: [PastSession] = []
        for candidate in candidates where found.count < limit {
            if let session = read(candidate.path, id: candidate.id, modified: candidate.modified) {
                found.append(session)
            }
        }
        return found
    }

    /// The head of a transcript holds the cwd and the first typed prompt; the
    /// tail holds the latest name records. Only those two slices are read.
    private static func read(_ path: String, id: String, modified: Date) -> PastSession? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        try? handle.seek(toOffset: 0)
        let head = String(decoding: (try? handle.read(upToCount: 65_536)) ?? Data(), as: UTF8.self)
        try? handle.seek(toOffset: size - min(size, 262_144))
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)

        var cwd: String?
        var firstPrompt: String?
        for line in head.split(separator: "\n") {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil, let value = entry["cwd"] as? String { cwd = value }
            if firstPrompt == nil, entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
               let message = entry["message"] as? [String: Any] {
                firstPrompt = TranscriptParser.typedPrompt(from: message).map { String($0.prefix(80)) }
            }
            if cwd != nil, firstPrompt != nil { break }
        }
        guard let cwd else { return nil }

        // A HUD or --name name wins over /rename, which wins over Claude Code's
        // own generated title; within a kind, the latest line wins.
        var names: [String: String] = [:]
        let kinds = ["agent-name": "agentName", "custom-title": "customTitle", "ai-title": "aiTitle"]
        for line in tail.split(separator: "\n").reversed() where names.count < kinds.count {
            for (kind, key) in kinds where names[kind] == nil && line.hasPrefix("{\"type\":\"\(kind)\"") {
                if let value = TranscriptParser.stringValues(of: key, in: line).first, !value.isEmpty {
                    names[kind] = value
                }
            }
        }
        let name = names["agent-name"] ?? names["custom-title"] ?? names["ai-title"]
        // Nothing typed and never titled: a one-shot or helper run, not worth resuming.
        guard name != nil || firstPrompt != nil else { return nil }
        return PastSession(
            transcript: TranscriptRef(cwd: cwd, sessionId: id),
            name: name, firstPrompt: firstPrompt, lastActive: modified
        )
    }
}
