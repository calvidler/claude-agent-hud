// Claude Agent HUD: a small always-on-top panel showing the state of local Claude Code
// sessions. Data sources, all local unless noted:
//   - `claude agents --json` for the session list and status (polled every 4s)
//   - each session's transcript tail (~/.claude/projects/...) for the last typed
//     prompt, context token count, and model, when those toggles are on
//   - Anthropic's usage endpoint, via the Claude Code OAuth token in the Keychain,
//     only while "Show usage left" is on (polled every 60s)
// Build and relaunch with ./build.sh.

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

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
}

struct Subagent: Identifiable, Equatable {
    let id: String
    let description: String
    let running: Bool
}

struct UsageLimit: Identifiable, Equatable {
    let label: String
    let percent: Int
    let severity: String
    var id: String { label }
}

// MARK: - Preferences

enum DisplayMode: String, CaseIterable, Codable, Identifiable {
    case overlay, window, dropdown
    var id: String { rawValue }

    var label: String {
        switch self {
        case .overlay: return "Overlay (always on top)"
        case .window: return "Window (can go behind)"
        case .dropdown: return "Menu bar dropdown"
        }
    }
}

enum RowOrder: String, CaseIterable, Codable, Identifiable {
    case attention, newest, oldest, name
    var id: String { rawValue }

    var label: String {
        switch self {
        case .attention: return "Needs attention first"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .name: return "By name"
        }
    }
}

struct RGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        (r, g, b, a) = (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }

    /// Resolves a dynamic system colour against the app's current light/dark
    /// appearance; without this the wrong variant is captured at launch.
    init(nsColor: NSColor) {
        var resolved = nsColor
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = nsColor.usingColorSpace(.sRGB) ?? .black
        }
        (r, g, b, a) = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent, 1)
    }
}

/// Property names are the persistence format (synthesized CodingKeys); renaming
/// one orphans its saved value.
struct Prefs: Codable, Equatable {
    var order = RowOrder.attention
    var background = RGBA(nsColor: .windowBackgroundColor)
    var backgroundOpacity = 0.8
    var text = RGBA(nsColor: .labelColor)
    var textOpacity = 0.9
    var deadAfterHours = 6.0
    var showLastPrompt = false
    var showContext = false
    var contextWarnPct = 0.6
    var showUsage = false
    var displayMode = DisplayMode.overlay
    var showInDock = false
    var showModel = false
    var notifyHighContext = true
    var notifyWaiting = false
    var notifyFinished = false
}

// Tolerant decoding: a saved blob missing newly added fields keeps its known
// values and takes defaults for the rest, instead of resetting everything.
extension Prefs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        order = (try? c.decode(RowOrder.self, forKey: .order)) ?? d.order
        background = (try? c.decode(RGBA.self, forKey: .background)) ?? d.background
        backgroundOpacity = (try? c.decode(Double.self, forKey: .backgroundOpacity)) ?? d.backgroundOpacity
        text = (try? c.decode(RGBA.self, forKey: .text)) ?? d.text
        textOpacity = (try? c.decode(Double.self, forKey: .textOpacity)) ?? d.textOpacity
        deadAfterHours = (try? c.decode(Double.self, forKey: .deadAfterHours)) ?? d.deadAfterHours
        showLastPrompt = (try? c.decode(Bool.self, forKey: .showLastPrompt)) ?? d.showLastPrompt
        showContext = (try? c.decode(Bool.self, forKey: .showContext)) ?? d.showContext
        contextWarnPct = (try? c.decode(Double.self, forKey: .contextWarnPct)) ?? d.contextWarnPct
        showUsage = (try? c.decode(Bool.self, forKey: .showUsage)) ?? d.showUsage
        displayMode = (try? c.decode(DisplayMode.self, forKey: .displayMode)) ?? d.displayMode
        showInDock = (try? c.decode(Bool.self, forKey: .showInDock)) ?? d.showInDock
        showModel = (try? c.decode(Bool.self, forKey: .showModel)) ?? d.showModel
        notifyHighContext = (try? c.decode(Bool.self, forKey: .notifyHighContext)) ?? d.notifyHighContext
        notifyWaiting = (try? c.decode(Bool.self, forKey: .notifyWaiting)) ?? d.notifyWaiting
        notifyFinished = (try? c.decode(Bool.self, forKey: .notifyFinished)) ?? d.notifyFinished
    }
}

final class Settings: ObservableObject {
    @Published var prefs: Prefs
    private var saver: AnyCancellable?

    init() {
        if let data = UserDefaults.standard.data(forKey: "prefs"),
           let decoded = try? JSONDecoder().decode(Prefs.self, from: data) {
            prefs = decoded
        } else {
            prefs = Prefs()
        }
        saver = $prefs
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { prefs in
                if let data = try? JSONEncoder().encode(prefs) {
                    UserDefaults.standard.set(data, forKey: "prefs")
                }
            }
    }
}

// MARK: - Shell

enum Shell {
    /// Runs a command to completion and returns its exit status and stdout.
    @discardableResult
    static func run(
        _ path: String, _ arguments: [String], environment: [String: String]? = nil
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Agent model

final class AgentModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var errorMessage: String?
    @Published var now = Date()

    // Status transitions observed by the HUD; the CLI only reports the current
    // status, so these clocks start when the HUD first sees the state.
    @Published var busySince: [String: Date] = [:]
    @Published var idleSince: [String: Date] = [:]
    @Published var dismissed: Set<String> = []

    // Per-session detail read from transcript tails.
    @Published var lastPrompts: [String: String] = [:]
    @Published var contextTokens: [String: Int] = [:]
    @Published var modelNames: [String: String] = [:]
    @Published var subagents: [String: [Subagent]] = [:]
    @Published var defaultWindowTokens = 200_000

    @Published var usage: [UsageLimit] = []

    // Mirrors of the prefs this model acts on, kept current by AppDelegate.
    var showPrompts = false
    var showContext = true
    var showUsage = false
    var showModel = false
    var warnFraction = 0.6
    var notifyContext = true
    var notifyWaiting = false
    var notifyFinished = false

    private var warned: Set<String> = []
    private var notifiedWaiting: Set<String> = []
    private var polling = false
    private var fetchingUsage = false
    private let claudePath = "/opt/homebrew/bin/claude"

    func start() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        poll()
        refreshUsage()
    }

    // MARK: Session polling

    private enum FetchError: Error {
        case cantRun, failed, badOutput

        var message: String {
            switch self {
            case .cantRun: return "can't run claude"
            case .failed: return "claude agents failed"
            case .badOutput: return "unexpected output"
            }
        }
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.fetchSessions()
            let defaultWindow = Self.readDefaultWindow()
            var details: [String: TranscriptDetail] = [:]
            if case .success(let sessions) = result {
                for session in sessions {
                    details[session.sessionId] = Self.readTranscriptDetail(
                        for: session,
                        wantPrompt: self.showPrompts,
                        wantAssistantInfo: self.showContext || self.showModel
                    )
                }
            }
            DispatchQueue.main.async {
                self.apply(result, details: details, defaultWindow: defaultWindow)
            }
        }
    }

    private func apply(
        _ result: Result<[AgentSession], FetchError>,
        details: [String: TranscriptDetail],
        defaultWindow: Int
    ) {
        polling = false
        defaultWindowTokens = defaultWindow
        switch result {
        case .success(let sessions):
            self.sessions = sessions
            lastPrompts = details.compactMapValues(\.prompt)
            contextTokens = details.compactMapValues(\.contextTokens)
            modelNames = details.compactMapValues(\.model)
            subagents = details.mapValues(\.subagents)
            let wasBusy = Set(busySince.keys)
            busySince = Self.transitionClocks(busySince, nowIn: sessions.ids(in: .busy))
            if notifyFinished {
                for session in sessions where session.state == .idle && wasBusy.contains(session.sessionId) {
                    notify("\(session.displayName) finished")
                }
            }
            idleSince = Self.transitionClocks(idleSince, nowIn: sessions.ids(in: .idle))
            dismissed.subtract(Set(sessions.filter { $0.state != .idle }.map(\.sessionId)))
            checkContextWarnings(sessions)
            checkWaitingNotifications(sessions)
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.message
        }
    }

    private func fetchSessions() -> Result<[AgentSession], FetchError> {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let (status, output) = Shell.run(claudePath, ["agents", "--json"], environment: environment)
        guard status == 0 else {
            return .failure(status == -1 ? .cantRun : .failed)
        }
        guard let sessions = try? JSONDecoder().decode([AgentSession].self, from: Data(output.utf8)) else {
            return .failure(.badOutput)
        }
        return .success(sessions)
    }

    /// Keeps a start date per id: drops ids no longer present, stamps new ones now.
    private static func transitionClocks(
        _ existing: [String: Date], nowIn ids: Set<String>
    ) -> [String: Date] {
        var clocks = existing.filter { ids.contains($0.key) }
        for id in ids where clocks[id] == nil {
            clocks[id] = Date()
        }
        return clocks
    }

    // MARK: Transcript detail

    private struct TranscriptDetail {
        var prompt: String?
        var contextTokens: Int?
        var model: String?
        var subagents: [Subagent] = []
    }

    /// Reads the tail of the session's local transcript for the latest typed
    /// prompt and the latest reply's token usage and model. Local file read only.
    private static func readTranscriptDetail(
        for session: AgentSession, wantPrompt: Bool, wantAssistantInfo: Bool
    ) -> TranscriptDetail {
        var detail = TranscriptDetail()
        guard let text = readTail(ofTranscriptFor: session) else { return detail }
        var spawns: [(id: String, description: String)] = []
        var finishedIds = Set<String>()
        for line in text.split(separator: "\n").reversed() {
            // Subagent spawns and completions are string-scanned rather than
            // JSON-parsed; result lines can be huge and this runs every poll.
            if line.contains("\"name\":\"Agent\"") || line.contains("\"name\":\"Task\"") {
                spawns.append(contentsOf: Self.subagentSpawns(in: line))
            } else if line.contains("\"tool_use_id\"") {
                finishedIds.formUnion(Self.stringValues(of: "tool_use_id", in: line))
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
            if !promptDone, type == "user", entry["isMeta"] as? Bool != true {
                detail.prompt = Self.typedPrompt(from: message)
            }
        }
        // Scanned newest-first; show oldest-first, capped to the recent few.
        detail.subagents = spawns.reversed().suffix(6).map {
            Subagent(id: $0.id, description: $0.description, running: !finishedIds.contains($0.id))
        }
        return detail
    }

    /// Agent/Task tool_use blocks in a transcript line, as (tool id, description).
    private static func subagentSpawns(in line: Substring) -> [(id: String, description: String)] {
        let ids = stringValues(of: "id", in: line, requiredPrefix: "toolu_")
        let descriptions = stringValues(of: "description", in: line)
        return zip(ids, descriptions).map { ($0, $1) }
    }

    /// Occurrences of "key":"value" in raw JSON text, without a full parse.
    private static func stringValues(
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

    private static func readTail(ofTranscriptFor session: AgentSession) -> String? {
        // Claude Code names transcript folders by replacing every
        // non-alphanumeric character of the cwd with a dash.
        let munged = String(session.cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let path = NSHomeDirectory() + "/.claude/projects/\(munged)/\(session.sessionId).jsonl"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size - min(size, 262_144))
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func contextTokens(from usage: [String: Any]) -> Int? {
        let input = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        guard input > 0 else { return nil }
        return input + (usage["output_tokens"] as? Int ?? 0)
    }

    /// The human-typed text of a user entry, or nil for tool results and
    /// command/system wrapper messages.
    private static func typedPrompt(from message: [String: Any]) -> String? {
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

    // MARK: Context window

    /// The transcript doesn't record the context window, so infer it: [1m] in
    /// the user's default model means 1M sessions, and a session already past
    /// 200k tokens must be on a 1M window.
    private static func readDefaultWindow() -> Int {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = parsed["model"] as? String else { return 200_000 }
        return model.contains("[1m]") ? 1_000_000 : 200_000
    }

    func windowTokens(for sessionId: String) -> Int {
        let tokens = contextTokens[sessionId] ?? 0
        return tokens > 200_000 ? 1_000_000 : defaultWindowTokens
    }

    private func checkContextWarnings(_ sessions: [AgentSession]) {
        guard showContext else { return }
        for session in sessions {
            guard let tokens = contextTokens[session.sessionId] else { continue }
            let fraction = Double(tokens) / Double(windowTokens(for: session.sessionId))
            if fraction >= warnFraction {
                // Notify once per crossing; re-arms when the session drops back
                // below the threshold (i.e. after a compact).
                if !warned.contains(session.sessionId) {
                    warned.insert(session.sessionId)
                    if notifyContext {
                        notifyHighContext(session: session, percent: Int(fraction * 100))
                    }
                }
            } else {
                warned.remove(session.sessionId)
            }
        }
    }

    private func notifyHighContext(session: AgentSession, percent: Int) {
        notify("\(session.displayName) is at \(percent)% context, consider /compact")
    }

    /// Notifies once per stretch of waiting; re-arms when the session resumes.
    private func checkWaitingNotifications(_ sessions: [AgentSession]) {
        let waiting = sessions.ids(in: .waiting)
        if notifyWaiting {
            for session in sessions where session.state == .waiting
                && !notifiedWaiting.contains(session.sessionId) {
                notify("\(session.displayName) needs input")
            }
        }
        notifiedWaiting = waiting
    }

    private func notify(_ body: String) {
        let cleaned = body.replacingOccurrences(of: "\"", with: "")
        let script = "display notification \"\(cleaned)\" with title \"Claude Agent HUD\""
        DispatchQueue.global(qos: .utility).async {
            Shell.run("/usr/bin/osascript", ["-e", script])
        }
    }

    // MARK: Usage limits

    /// Reads the Claude Code OAuth token from the Keychain and asks Anthropic's
    /// usage endpoint for the account's rate-limit status. Only runs while the
    /// toggle is on; the token is sent nowhere except api.anthropic.com.
    func refreshUsage() {
        guard showUsage, !fetchingUsage else { return }
        fetchingUsage = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let limits = Self.fetchUsageLimits()
            DispatchQueue.main.async {
                self?.fetchingUsage = false
                if let limits { self?.usage = limits }
            }
        }
    }

    private static func fetchUsageLimits() -> [UsageLimit]? {
        let raw = Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        ).output
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = parsed["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        var result: [UsageLimit]?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let limits = body["limits"] as? [[String: Any]] else { return }
            result = limits.compactMap(Self.usageLimit(from:))
        }.resume()
        done.wait()
        return result
    }

    private static func usageLimit(from limit: [String: Any]) -> UsageLimit? {
        guard let percent = limit["percent"] as? Int else { return nil }
        let kind = limit["kind"] as? String ?? ""
        let label: String
        switch kind {
        case "session":
            label = "5h"
        case "weekly_all":
            label = "week"
        default:
            let scopeModel = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
            label = (scopeModel?["display_name"] as? String)?.lowercased() ?? kind
        }
        return UsageLimit(
            label: label,
            percent: percent,
            severity: limit["severity"] as? String ?? "normal"
        )
    }
}

private extension [AgentSession] {
    func ids(in state: SessionStatus) -> Set<String> {
        Set(filter { $0.state == state }.map(\.sessionId))
    }
}

// MARK: - Terminal focus

/// Jumps to the terminal a session lives in: finds the session's tty and the
/// nearest ancestor GUI app, selects the matching Terminal.app tab, and
/// activates the app. Other terminals still get activated, just without tab
/// selection.
enum TerminalFocus {
    static func focus(pid: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tty = Shell.run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let app = ancestorApp(of: pid_t(pid))
            if app?.bundleIdentifier == "com.apple.Terminal", !tty.isEmpty, tty != "??" {
                selectTerminalTab(tty: "/dev/\(tty)")
            }
            DispatchQueue.main.async {
                app?.activate()
            }
        }
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

    private static func selectTerminalTab(tty: String) {
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                    end if
                end repeat
            end repeat
        end tell
        """
        Shell.run("/usr/bin/osascript", ["-e", script])
    }
}

// MARK: - HUD view

struct HUDView: View {
    @ObservedObject var model: AgentModel
    @ObservedObject var settings: Settings
    let onClose: () -> Void
    let onSettings: () -> Void
    @State private var hoveredId: String?
    @State private var expandedIds: Set<String> = []

    private static let deadDot = Color(red: 0.75, green: 0.2, blue: 0.2)
    private static let closeDot = Color(red: 1, green: 0.37, blue: 0.34)

    var body: some View {
        content
            .background(
                settings.prefs.background.color.opacity(settings.prefs.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .padding(6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            topBar
            divider
            if let message = model.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
            } else if model.sessions.isEmpty {
                Text("No agents running")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
            } else {
                ForEach(ordered) { session in
                    row(session)
                    if expandedIds.contains(session.sessionId) {
                        subagentRows(session)
                    }
                }
            }
            if settings.prefs.showUsage, !model.usage.isEmpty {
                divider
                usageFooter
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Circle()
                    .fill(Self.closeDot)
                    .frame(width: 9, height: 9)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Claude Agent HUD")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(secondaryText)
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 2)
    }

    private var divider: some View {
        Rectangle()
            .fill(primaryText.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 2)
    }

    private var usageFooter: some View {
        HStack(spacing: 10) {
            ForEach(model.usage) { limit in
                Text("\(limit.label) \(limit.percent)%")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(usageColor(limit))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 1)
    }

    // MARK: Rows

    private func row(_ session: AgentSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isDead(session) ? Self.deadDot : statusColor(session.state))
                .frame(width: 7, height: 7)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                if settings.prefs.showLastPrompt,
                   let prompt = model.lastPrompts[session.sessionId] {
                    Text(prompt)
                        .font(.system(size: 10))
                        .italic()
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Text(subtitle(session))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(session.state == .waiting ? Color.orange : secondaryText)
                    .lineLimit(1)
            }
            .allowsHitTesting(false)
            Spacer(minLength: 0)
            if settings.prefs.showContext, !isDead(session),
               let percent = contextPercent(session) {
                Text("\(percent)%")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(contextColor(percent))
                    .allowsHitTesting(false)
            }
            if isDead(session) {
                Button {
                    model.dismissed.insert(session.sessionId)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear this session from the list")
            }
            if !(model.subagents[session.sessionId] ?? []).isEmpty {
                Button {
                    toggleExpanded(session.sessionId)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .rotationEffect(.degrees(expandedIds.contains(session.sessionId) ? 90 : 0))
                }
                .buttonStyle(.plain)
                .help("Show subagents")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(hoveredId == session.id ? 0.09 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredId = session.id
                NSCursor.pointingHand.set()
            } else {
                if hoveredId == session.id { hoveredId = nil }
                NSCursor.arrow.set()
            }
        }
        .onTapGesture {
            TerminalFocus.focus(pid: session.pid)
        }
        .contextMenu {
            Button("Jump to terminal") { TerminalFocus.focus(pid: session.pid) }
            Button("Reveal folder in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
            }
            Divider()
            Button("Copy folder path") { copy(session.cwd) }
            Button("Copy session ID") { copy(session.sessionId) }
            Divider()
            if !(model.subagents[session.sessionId] ?? []).isEmpty {
                Button(expandedIds.contains(session.sessionId) ? "Hide subagents" : "Show subagents") {
                    toggleExpanded(session.sessionId)
                }
            }
            Button("Hide from list") { model.dismissed.insert(session.sessionId) }
        }
    }

    private func toggleExpanded(_ sessionId: String) {
        if expandedIds.contains(sessionId) {
            expandedIds.remove(sessionId)
        } else {
            expandedIds.insert(sessionId)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func subagentRows(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.subagents[session.sessionId] ?? []) { subagent in
                HStack(spacing: 6) {
                    Circle()
                        .fill(subagent.running ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text(subagent.description)
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(subagent.running ? "running" : "done")
                        .font(.system(size: 9))
                        .foregroundStyle(subagent.running ? Color.green : secondaryText)
                }
            }
        }
        .padding(.leading, 27)
        .padding(.trailing, 8)
        .padding(.bottom, 2)
    }

    private var visible: [AgentSession] {
        model.sessions.filter { !model.dismissed.contains($0.sessionId) }
    }

    private var ordered: [AgentSession] {
        switch settings.prefs.order {
        case .attention:
            return visible.sorted { (rank($0), $0.startedAt) < (rank($1), $1.startedAt) }
        case .newest:
            return visible.sorted { $0.startedAt > $1.startedAt }
        case .oldest:
            return visible.sorted { $0.startedAt < $1.startedAt }
        case .name:
            return visible.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    private func rank(_ session: AgentSession) -> Int {
        isDead(session) ? 3 : session.state.rank
    }

    private func isDead(_ session: AgentSession) -> Bool {
        guard session.state == .idle,
              let since = model.idleSince[session.sessionId] else { return false }
        return model.now.timeIntervalSince(since) >= settings.prefs.deadAfterHours * 3600
    }

    // MARK: Row text

    private func subtitle(_ session: AgentSession) -> String {
        var text = statusText(session)
        if settings.prefs.showModel, let name = model.modelNames[session.sessionId] {
            text += " · \(name.hasPrefix("claude-") ? String(name.dropFirst(7)) : name)"
        }
        return text
    }

    private func statusText(_ session: AgentSession) -> String {
        switch session.state {
        case .waiting:
            return session.waitingFor ?? "waiting"
        case .idle:
            guard let since = model.idleSince[session.sessionId] else { return "idle" }
            let prefix = isDead(session) ? "dead, idle" : "idle"
            return "\(prefix) \(duration(since: since))"
        case .busy:
            guard let since = model.busySince[session.sessionId] else { return "working" }
            return "working \(duration(since: since))"
        }
    }

    private func duration(since: Date) -> String {
        let seconds = max(0, Int(model.now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    private func contextPercent(_ session: AgentSession) -> Int? {
        guard let tokens = model.contextTokens[session.sessionId] else { return nil }
        return Int(Double(tokens) / Double(model.windowTokens(for: session.sessionId)) * 100)
    }

    // MARK: Colours

    private var primaryText: Color {
        settings.prefs.text.color.opacity(settings.prefs.textOpacity)
    }

    private var secondaryText: Color {
        settings.prefs.text.color.opacity(settings.prefs.textOpacity * 0.65)
    }

    private func statusColor(_ state: SessionStatus) -> Color {
        switch state {
        case .busy: return .green
        case .waiting: return .orange
        case .idle: return Color.secondary.opacity(0.5)
        }
    }

    private func contextColor(_ percent: Int) -> Color {
        if percent >= 85 { return .red }
        if Double(percent) >= settings.prefs.contextWarnPct * 100 { return .orange }
        return secondaryText
    }

    private func usageColor(_ limit: UsageLimit) -> Color {
        switch limit.severity {
        case "warning": return .orange
        case "normal": return secondaryText
        default: return .red
        }
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var tab = Tab.general
    @State private var resetToken = 0

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case details = "Details"
        case appearance = "Appearance"
        case notifications = "Notifications"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 18) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .general: generalTab
            case .details: detailsTab
            case .appearance: appearanceTab
            case .notifications: notificationsTab
            }
        }
        .padding(20)
        .frame(width: 440)
        .id(resetToken)
    }

    // MARK: Tabs

    private var generalTab: some View {
        VStack(spacing: 16) {
            SettingsSection {
                SettingsRow("Display") {
                    Picker("", selection: $settings.prefs.displayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                SettingsRow("Show in Dock") { SettingsSwitch(isOn: $settings.prefs.showInDock) }
                SettingsRow("Toggle panel") {
                    Text("⌥⌘A").foregroundStyle(.secondary)
                }
            }
            SettingsSection(footer: "Sessions idle longer than this are marked dead and can be cleared from the list.") {
                SettingsRow("Row order") {
                    Picker("", selection: $settings.prefs.order) {
                        ForEach(RowOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                SettingsRow("Dead after \(deadAfterLabel)") {
                    Slider(value: $settings.prefs.deadAfterHours, in: 0.5...6, step: 0.5)
                        .frame(width: 160)
                }
            }
            Button("Reset all settings") {
                NSColorPanel.shared.close()
                settings.prefs = Prefs()
                resetToken += 1  // rebuild the view so colour swatches refresh
            }
            .controlSize(.small)
        }
    }

    private var detailsTab: some View {
        VStack(spacing: 16) {
            SettingsSection(header: "Show per session") {
                SettingsRow("Last prompt") { SettingsSwitch(isOn: $settings.prefs.showLastPrompt) }
                SettingsRow("Model") { SettingsSwitch(isOn: $settings.prefs.showModel) }
                SettingsRow("Context %") { SettingsSwitch(isOn: $settings.prefs.showContext) }
                SettingsRow("Warn above \(Int(settings.prefs.contextWarnPct * 100))%") {
                    Slider(value: $settings.prefs.contextWarnPct, in: 0.3...0.9, step: 0.05)
                        .frame(width: 160)
                }
                .disabled(!settings.prefs.showContext)
            }
            SettingsSection(
                header: "Account",
                footer: "Reads your Claude Code sign-in token from the Keychain to ask Anthropic for your limits. The token is sent only to api.anthropic.com."
            ) {
                SettingsRow("Usage left") { SettingsSwitch(isOn: $settings.prefs.showUsage) }
            }
        }
    }

    private var appearanceTab: some View {
        VStack(spacing: 16) {
            SettingsSection(header: "Background") {
                SettingsRow("Colour") {
                    ColorPicker("", selection: backgroundColor, supportsOpacity: false).labelsHidden()
                }
                SettingsRow("Opacity") {
                    Slider(value: $settings.prefs.backgroundOpacity, in: 0.05...1).frame(width: 160)
                }
            }
            SettingsSection(header: "Text") {
                SettingsRow("Colour") {
                    ColorPicker("", selection: textColor, supportsOpacity: false).labelsHidden()
                }
                SettingsRow("Opacity") {
                    Slider(value: $settings.prefs.textOpacity, in: 0.2...1).frame(width: 160)
                }
            }
        }
    }

    private var notificationsTab: some View {
        SettingsSection(
            header: "Notify when a session is",
            footer: "High context uses the warn threshold from Details and needs Context % on. Each notification fires once per episode."
        ) {
            SettingsRow("Waiting for input") { SettingsSwitch(isOn: $settings.prefs.notifyWaiting) }
            SettingsRow("Finished working") { SettingsSwitch(isOn: $settings.prefs.notifyFinished) }
            SettingsRow("High context") { SettingsSwitch(isOn: $settings.prefs.notifyHighContext) }
        }
    }

    // MARK: Helpers

    private var deadAfterLabel: String {
        let hours = settings.prefs.deadAfterHours
        if hours < 1 { return "\(Int(hours * 60))m" }
        return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { settings.prefs.background.color },
            set: { settings.prefs.background = RGBA(color: $0) }
        )
    }

    private var textColor: Binding<Color> {
        Binding(
            get: { settings.prefs.text.color },
            set: { settings.prefs.text = RGBA(color: $0) }
        )
    }
}

/// A card of rows with hairline separators, plus optional header and footer text.
struct SettingsSection<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            _VariadicView.Tree(SeparatedRows()) { content }
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private struct SeparatedRows: _VariadicView_MultiViewRoot {
        @ViewBuilder
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    child
                    if child.id != children.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }
}

/// One label-left, control-right settings row.
struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.blue)
            .controlSize(.small)
    }
}

// MARK: - Global hotkey

/// A system-wide hotkey via Carbon; works without accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, context, &handlerRef)
        let hotKeyId = EventHotKeyID(signature: 0x4148_5544, id: 1)  // "AHUD"
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyId,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var popover: NSPopover?
    private var lastMode: DisplayMode?
    private var settingsWindow: NSWindow?
    private let model = AgentModel()
    private let settings = Settings()
    private var settingsObservation: AnyCancellable?
    private var hotKey: HotKey?
    private let contextMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyPrefs(settings.prefs)
        settingsObservation = settings.$prefs.sink { [weak self] prefs in
            self?.applyPrefs(prefs)
        }
        model.start()
        makePanel()
        makeStatusItem()
        applyDisplay(settings.prefs)
        hotKey = HotKey(keyCode: kVK_ANSI_A, modifiers: cmdKey | optionKey) { [weak self] in
            self?.togglePanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("Show panel", #selector(showPanel)),
            ("Hide panel", #selector(hidePanel)),
            ("Settings…", #selector(openSettings)),
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Prefs application

    private func applyPrefs(_ prefs: Prefs) {
        model.showPrompts = prefs.showLastPrompt
        model.showContext = prefs.showContext
        model.showModel = prefs.showModel
        model.warnFraction = prefs.contextWarnPct
        model.notifyContext = prefs.notifyHighContext
        model.notifyWaiting = prefs.notifyWaiting
        model.notifyFinished = prefs.notifyFinished
        let usageTurnedOn = !model.showUsage && prefs.showUsage
        model.showUsage = prefs.showUsage
        if usageTurnedOn { model.refreshUsage() }
        applyDisplay(prefs)
    }

    private func applyDisplay(_ prefs: Prefs) {
        guard panel != nil else { return }  // sink can fire before makePanel
        NSApp.setActivationPolicy(prefs.showInDock ? .regular : .accessory)
        guard prefs.displayMode != lastMode else { return }
        lastMode = prefs.displayMode
        switch prefs.displayMode {
        case .overlay:
            popover?.performClose(nil)
            panel.level = .statusBar
            panel.orderFrontRegardless()
        case .window:
            popover?.performClose(nil)
            panel.level = .normal
            panel.orderFrontRegardless()
        case .dropdown:
            panel.orderOut(nil)
        }
    }

    // MARK: UI construction

    private func makeHUD(onClose: @escaping () -> Void) -> NSHostingController<HUDView> {
        NSHostingController(
            rootView: HUDView(
                model: model,
                settings: settings,
                onClose: onClose,
                onSettings: { [weak self] in self?.openSettings() }
            )
        )
    }

    private func makePanel() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = makeHUD(onClose: { [weak self] in
            self?.panel.orderOut(nil)
        })
        if let contentView = panel.contentViewController?.view {
            panel.setContentSize(contentView.fittingSize)
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(
                x: frame.maxX - panel.frame.width - 12,
                y: frame.maxY - 12
            ))
        }
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude Agent HUD")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        addMenuItem("Show panel", action: #selector(showPanel))
        addMenuItem("Settings…", action: #selector(openSettings), key: ",")
        contextMenu.addItem(.separator())
        addMenuItem("Quit Claude Agent HUD", action: #selector(quit), key: "q")
    }

    private func addMenuItem(_ title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        contextMenu.addItem(item)
    }

    private func showDropdown() {
        if popover == nil {
            let created = NSPopover()
            created.behavior = .transient
            created.contentViewController = makeHUD(onClose: { [weak self] in
                self?.popover?.performClose(nil)
            })
            popover = created
        }
        guard let popover, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // A status item can't have both a click action and a menu; attach
            // the menu just long enough to pop it open.
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        togglePanel()
    }

    private func togglePanel() {
        if settings.prefs.displayMode == .dropdown {
            showDropdown()
        } else if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func showPanel() {
        if settings.prefs.displayMode == .dropdown {
            showDropdown()
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func hidePanel() {
        popover?.performClose(nil)
        panel.orderOut(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView(settings: settings))
            )
            window.title = "Claude Agent HUD Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
