import Combine
import Foundation

// MARK: - Auto-naming

/// Sessions currently being named, so the HUD can show progress.
final class AutoNameStatus: ObservableObject {
    static let shared = AutoNameStatus()
    @Published var inFlight: Set<String> = []
}

/// Suggests a session name from its transcript using a headless Haiku call on
/// the user's Claude Code login (cheap, no API key), then applies it quietly
/// via SessionRegistry. The helper runs with no tools, no saved session, and
/// in an empty folder, and is filtered out of the session list by its name.
enum AutoNamer {
    static let helperSessionName = "claude-agent-hud-namer"
    private static let queue = DispatchQueue(label: "agent-hud.autonamer")

    /// Called on the main thread after a session is auto-named, with its id.
    static var onNamed: ((String) -> Void)?

    static func rename(_ session: AgentSession) {
        DispatchQueue.main.async { AutoNameStatus.shared.inFlight.insert(session.sessionId) }
        queue.async {
            let result = suggestName(for: session.transcript)
            DispatchQueue.main.async {
                AutoNameStatus.shared.inFlight.remove(session.sessionId)
                switch result {
                case .success(let name):
                    SessionRegistry.setName(name, for: session)
                    onNamed?(session.sessionId)
                case .failure(let error):
                    Notifier.post("Auto-name failed for \(session.displayName): \(error.reason)")
                }
            }
        }
    }

    /// Names a finished session; the new name (or nil on failure) is handed
    /// back on the main thread.
    static func rename(past session: PastSession, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async { AutoNameStatus.shared.inFlight.insert(session.id) }
        queue.async {
            let result = suggestName(for: session.transcript)
            DispatchQueue.main.async {
                AutoNameStatus.shared.inFlight.remove(session.id)
                switch result {
                case .success(let name):
                    SessionRegistry.setName(name, forPast: session.transcript)
                    completion(name)
                case .failure(let error):
                    Notifier.post("Auto-name failed for \(session.displayName): \(error.reason)")
                    completion(nil)
                }
            }
        }
    }

    private struct NamingError: Error {
        let reason: String
    }

    static func renameAll(_ sessions: [AgentSession]) {
        for session in sessions {
            rename(session)
        }
    }

    private static func suggestName(for transcript: TranscriptRef) -> Result<String, NamingError> {
        guard let excerpt = recentExcerpt(for: transcript) else {
            return .success(fallbackName(cwd: transcript.cwd))
        }
        let instruction = """
        You are naming a coding session so a developer can tell it apart from others at a glance. \
        Below are whichever of these exist: the developer's recent requests (oldest first), the files \
        edited most recently, subagent tasks, and if nothing was typed, the assistant's own summaries. \
        Reply with only a 2-5 word kebab-case name that identifies the feature, component, or distinctive \
        idea being worked on. Prefer concrete feature, component, or file names over generic verbs \
        (never things like fix-bug, update-code, general-work). Weight the most recent requests most. \
        No other text.
        """
        let (status, output) = Shell.run(
            ClaudeCLI.path,
            ["-p", "--no-session-persistence", "--model", "haiku", "--tools", "",
             "--output-format", "text", "-n", helperSessionName, instruction],
            environment: ClaudeCLI.environment, input: excerpt, currentDirectory: scratchDirectory(), timeout: 90
        )
        let raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard status == 0 else {
            return .failure(NamingError(reason: "claude exited \(status): \(raw.prefix(80))"))
        }
        guard let cleaned = normalizeName(raw) else {
            return .failure(NamingError(reason: "unusable suggestion \"\(raw.prefix(80))\""))
        }
        return .success(cleaned)
    }

    /// An empty folder for the helper to run in. Claude Code scans its working
    /// directory at startup; running it in the home folder would touch
    /// protected locations like ~/Pictures and trigger permission prompts.
    private static func scratchDirectory() -> String {
        let dir = NSHomeDirectory() + "/Library/Caches/app.claude-agent-hud/namer"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// What the session has been about, strongest signals first: the user's
    /// last 20 typed prompts, the files edited most recently, subagent task
    /// descriptions, and (only when nothing was typed, e.g. a session driven by
    /// slash commands or resumed mid-task) a few of the assistant's own
    /// summaries. Nil when the transcript holds none of these.
    private static func recentExcerpt(for transcript: TranscriptRef) -> String? {
        // Whole transcript, not a tail: tool output can push the last typed
        // prompt megabytes back, and a tail then names the session off noise.
        guard let text = TranscriptParser.readTail(of: transcript, bytes: 64 * 1_048_576) else { return nil }
        var prompts: [String] = []
        var files: [String] = []
        var tasks: [String] = []
        var summaries: [String] = []
        let editTools = ["\"name\":\"Edit\"", "\"name\":\"Write\"", "\"name\":\"MultiEdit\"", "\"name\":\"NotebookEdit\""]
        let ignoredExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "pdf", "icns"]
        for line in text.split(separator: "\n").reversed() {
            if prompts.count >= 20, files.count >= 12 { break }
            if line.contains("\"tool_result\"") { continue }  // huge, and never a signal
            if files.count < 12, line.contains("\"file_path\":\""), editTools.contains(where: line.contains) {
                for path in TranscriptParser.stringValues(of: "file_path", in: line) {
                    let name = (path as NSString).lastPathComponent
                    let ext = (name as NSString).pathExtension.lowercased()
                    if !files.contains(name), !ignoredExtensions.contains(ext) { files.append(name) }
                }
            }
            if tasks.count < 6, line.contains("\"name\":\"Agent\"") || line.contains("\"name\":\"Task\"") {
                tasks.append(contentsOf: TranscriptParser.stringValues(of: "description", in: line))
            }
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = entry["message"] as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "user" where prompts.count < 20 && entry["isMeta"] as? Bool != true
                && entry["isCompactSummary"] as? Bool != true:
                if let prompt = TranscriptParser.typedPrompt(from: message) { prompts.append(prompt) }
            case "assistant" where summaries.count < 4:
                if let parts = message["content"] as? [[String: Any]],
                   let textPart = parts.first(where: { $0["type"] as? String == "text" }),
                   let textValue = textPart["text"] as? String {
                    let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > 40 { summaries.append(String(trimmed.prefix(240))) }
                }
            default:
                break
            }
        }
        var sections: [String] = []
        if !prompts.isEmpty {
            sections.append("Requests:\n" + prompts.reversed().map { "- \($0)" }.joined(separator: "\n"))
        }
        if !files.isEmpty {
            sections.append("Files edited recently (most recent first): " + files.prefix(12).joined(separator: ", "))
        }
        if !tasks.isEmpty {
            sections.append("Subagent tasks: " + tasks.prefix(6).joined(separator: "; "))
        }
        if prompts.isEmpty, !summaries.isEmpty {
            sections.append("Assistant summaries (newest first):\n" + summaries.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Lower-cased, with every run of anything else collapsed to one dash.
    static func kebabCased(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    /// A model's suggestion turned into a name, or nil if it is unusable: too
    /// short to mean anything, or long enough that the model ignored the brief.
    static func normalizeName(_ raw: String) -> String? {
        let cleaned = kebabCased(raw)
        return (3...48).contains(cleaned.count) ? cleaned : nil
    }

    /// Last resort when the transcript says nothing: the project folder name.
    static func fallbackName(cwd: String) -> String {
        let folder = kebabCased((cwd as NSString).lastPathComponent)
        return folder.isEmpty ? "untitled-session" : folder
    }
}
