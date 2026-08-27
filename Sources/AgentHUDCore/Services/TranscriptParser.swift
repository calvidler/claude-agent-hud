import Foundation

/// What one poll needs to know about a session, read from its transcript.
struct TranscriptDetail {
    var prompt: String?
    var contextTokens: Int?
    var model: String?
    var subagents: [Subagent] = []
    var promptId: String?
    var compactId: String?
    var permissionMode: String?
    var effort: String?
    var activity: String?
}

/// Reads Claude Code's transcript JSONL. Everything here is a function of the
/// bytes on disk: no process spawning, no UI state, nothing to mock.
enum TranscriptParser {
    /// Reads the tail of the session's local transcript for the latest typed
    /// prompt and the latest reply's token usage and model. Local file read only.
    static func detail(
        for transcript: TranscriptRef, wantPrompt: Bool, wantAssistantInfo: Bool
    ) -> TranscriptDetail {
        var detail = TranscriptDetail()
        guard let text = readTail(of: transcript) else { return detail }
        var spawns: [(id: String, description: String)] = []
        var finishedIds = Set<String>()
        var latestTool: (id: String, activity: String)?
        for line in text.split(separator: "\n").reversed() {
            if latestTool == nil, line.contains("\"type\":\"assistant\""), line.contains("\"type\":\"tool_use\""),
               let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let parts = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]],
               let block = parts.last(where: { $0["type"] as? String == "tool_use" }),
               let id = block["id"] as? String, let name = block["name"] as? String {
                latestTool = (id, Self.activityText(tool: name, input: block["input"] as? [String: Any] ?? [:]))
            }
            // Subagent spawns and completions are string-scanned rather than
            // JSON-parsed; result lines can be huge and this runs every poll.
            if line.contains("\"name\":\"Agent\"") || line.contains("\"name\":\"Task\"") {
                spawns.append(contentsOf: Self.subagentSpawns(in: line))
            } else if line.contains("\"tool_use_id\"") {
                finishedIds.formUnion(Self.stringValues(of: "tool_use_id", in: line))
            } else if detail.compactId == nil, line.contains("\"subtype\":\"compact_boundary\"") {
                detail.compactId = Self.stringValues(of: "uuid", in: line).first
            }
            // Every prompt records the mode it was sent in, and switching mode
            // writes its own record, so the newest mention is the current mode.
            if detail.permissionMode == nil, line.contains("\"permissionMode\":\"") {
                detail.permissionMode = Self.stringValues(of: "permissionMode", in: line).first
            }
            // Each reply records the effort level it ran at.
            if detail.effort == nil, line.contains("\"type\":\"assistant\""), line.contains("\"effort\":\"") {
                detail.effort = Self.stringValues(of: "effort", in: line).first
            }

            let promptDone = detail.prompt != nil || !wantPrompt
            let assistantDone = detail.contextTokens != nil || !wantAssistantInfo
            if promptDone && assistantDone { continue }
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = entry["message"] as? [String: Any] else { continue }
            let type = entry["type"] as? String
            if !assistantDone, type == "assistant",
               let usage = message["usage"] as? [String: Any] {
                detail.model = message["model"] as? String
                detail.contextTokens = Self.contextTokens(from: usage)
            }
            if !promptDone, type == "user", entry["isMeta"] as? Bool != true,
               entry["isCompactSummary"] as? Bool != true {
                detail.prompt = Self.typedPrompt(from: message)
                if detail.prompt != nil { detail.promptId = entry["uuid"] as? String }
            }
        }
        // Results always follow their call, so a result seen for the newest
        // call means the model has it back and is composing the next step.
        if let latestTool {
            detail.activity = finishedIds.contains(latestTool.id) ? "thinking" : latestTool.activity
        }
        // Scanned newest-first; show oldest-first, capped to the recent few.
        detail.subagents = spawns.reversed().suffix(6).map {
            Subagent(id: $0.id, description: $0.description, running: !finishedIds.contains($0.id))
        }
        return detail
    }

    /// Agent/Task tool_use blocks in a transcript line, as (tool id, description).
    /// Handled one block at a time so ids and descriptions pair correctly when
    /// the same reply also calls other tools.
    static func subagentSpawns(in line: Substring) -> [(id: String, description: String)] {
        line.components(separatedBy: "\"type\":\"tool_use\"").dropFirst().compactMap { block in
            guard block.contains("\"name\":\"Agent\"") || block.contains("\"name\":\"Task\""),
                  let id = stringValues(of: "id", in: Substring(block), requiredPrefix: "toolu_").first,
                  let description = stringValues(of: "description", in: Substring(block)).first
            else { return nil }
            return (id, description)
        }
    }

    /// Occurrences of "key":"value" in raw JSON text, without a full parse.
    static func stringValues(
        of key: String, in line: Substring, requiredPrefix: String? = nil
    ) -> [String] {
        var values: [String] = []
        let marker = "\"\(key)\":\""
        var search = line[...]
        while let start = search.range(of: marker) {
            search = search[start.upperBound...]
            guard let end = search.firstIndex(of: "\"") else { break }
            let value = String(search[..<end])
            if requiredPrefix == nil || value.hasPrefix(requiredPrefix!) {
                values.append(value)
            }
        }
        return values
    }

    static func readTail(of transcript: TranscriptRef, bytes: UInt64 = 262_144) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcript.path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size - min(size, bytes))
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One or two words for a tool call, e.g. "editing router.tsx". The line
    /// also carries the timer, model and mode, so it has to stay short.
    static func activityText(tool: String, input: [String: Any]) -> String {
        let file = (input["file_path"] as? String)
            .map { String(($0 as NSString).lastPathComponent.prefix(24)) }
        switch tool {
        case "Read": return "reading \(file ?? "")"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "editing \(file ?? "")"
        case "Bash": return "running"
        case "Grep", "Glob": return "searching"
        case "Agent", "Task": return "subagent"
        case "WebFetch", "WebSearch": return "browsing"
        case "Skill": return "/\(input["skill"] as? String ?? "skill")"
        case "AskUserQuestion": return "asking"
        default: return "working"
        }
    }

    static func contextTokens(from usage: [String: Any]) -> Int? {
        let input = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        guard input > 0 else { return nil }
        return input + (usage["output_tokens"] as? Int ?? 0)
    }

    /// The human-typed text of a user entry, or nil for tool results and
    /// command/system wrapper messages.
    static func typedPrompt(from message: [String: Any]) -> String? {
        var content: String?
        if let string = message["content"] as? String {
            content = string
        } else if let parts = message["content"] as? [[String: Any]] {
            guard !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            content = parts
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
        }
        guard var prompt = content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty, !prompt.hasPrefix("<") else { return nil }
        prompt = prompt.replacingOccurrences(of: "\n", with: " ")
        return String(prompt.prefix(140))
    }
}
