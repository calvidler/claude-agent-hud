import Foundation

// MARK: - Session data

enum SessionStatus: String {
    case waiting, busy, idle

    /// Attention order: waiting first, then busy, then idle.
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .busy: return 1
        case .idle: return 2
        }
    }
}

struct AgentSession: Identifiable, Decodable {
    let pid: Int
    let cwd: String
    let startedAt: Double
    let sessionId: String
    let name: String?
    let status: String
    let waitingFor: String?

    var id: String { sessionId }
    var state: SessionStatus { SessionStatus(rawValue: status) ?? .busy }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return (cwd as NSString).lastPathComponent
    }

    var transcript: TranscriptRef { TranscriptRef(cwd: cwd, sessionId: sessionId) }
}

/// A session's transcript on disk. Claude Code names transcript folders by
/// replacing every non-alphanumeric character of the cwd with a dash.
struct TranscriptRef {
    let cwd: String
    let sessionId: String

    var path: String {
        let munged = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return NSHomeDirectory() + "/.claude/projects/\(munged)/\(sessionId).jsonl"
    }
}

/// A session that is no longer running, found by its transcript.
struct PastSession: Identifiable {
    let transcript: TranscriptRef
    var name: String?
    let firstPrompt: String?
    let lastActive: Date

    var id: String { transcript.sessionId }
    var cwd: String { transcript.cwd }
    var folder: String { (cwd as NSString).lastPathComponent }
    var displayName: String { name ?? firstPrompt ?? folder }
}

struct Subagent: Identifiable, Equatable {
    let id: String
    let description: String
    let running: Bool
}

struct UsageLimit: Identifiable, Equatable, Codable {
    let label: String
    let percent: Int
    let severity: String
    var id: String { label }
}
