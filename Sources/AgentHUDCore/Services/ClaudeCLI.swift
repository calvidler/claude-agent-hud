import Foundation

/// Locating and running the `claude` CLI.
enum ClaudeCLI {
    enum FetchError: Error {
        case cantRun, failed, badOutput

        var message: String {
            switch self {
            case .cantRun: return "can't run claude"
            case .failed: return "claude agents failed"
            case .badOutput: return "unexpected output"
            }
        }
    }

    /// Resolved once per launch and shared by every caller.
    static let path = locate()

    /// A minimal PATH, so the CLI finds node and its own helpers without
    /// inheriting whatever the launching context happened to have.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return environment
    }

    /// Locates the `claude` CLI by checking the usual install paths. Deliberately
    /// no login-shell lookup: that would run the user's shell startup files with
    /// this app as the responsible process and can trigger privacy prompts.
    static func locate() -> String {
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted(by: >).map { "\(nvm)/\($0)/bin/claude" }
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? "/usr/local/bin/claude"
    }

    static func fetchSessions() -> Result<[AgentSession], FetchError> {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let (status, output) = Shell.run(path, ["agents", "--json"], environment: environment)
        guard status == 0 else {
            return .failure(status == -1 ? .cantRun : .failed)
        }
        // Decode per entry so one odd session (e.g. a headless helper missing a
        // field) is skipped rather than blanking the whole list.
        guard let entries = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [Any] else {
            return .failure(.badOutput)
        }
        let decoder = JSONDecoder()
        let sessions = entries.compactMap { entry -> AgentSession? in
            guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decoder.decode(AgentSession.self, from: data)
        }
        return .success(sessions)
    }
}
