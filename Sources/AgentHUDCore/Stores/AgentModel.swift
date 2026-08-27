import AppKit
import Combine
import Foundation

// MARK: - Agent model

final class AgentModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var errorMessage: String?
    @Published var now = Date()

    // Status transitions observed by the HUD; the CLI only reports the current
    // status, so these clocks start when the HUD first sees the state.
    @Published var busySince: [String: Date] = [:]
    @Published var idleSince: [String: Date] = [:]
    /// When each session last went from working to idle.
    @Published var finishedAt: [String: Date] = [:]
    @Published var dismissed: Set<String> = []

    // Per-session detail read from transcript tails.
    @Published var lastPrompts: [String: String] = [:]
    @Published var contextTokens: [String: Int] = [:]
    @Published var modelNames: [String: String] = [:]
    /// Claude Code permission mode per session (plan, auto, acceptEdits, ...).
    @Published var permissionModes: [String: String] = [:]
    @Published var efforts: [String: String] = [:]
    /// What a busy session is doing right now ("editing router.tsx").
    @Published var activities: [String: String] = [:]
    /// pid of the session in Terminal.app's selected tab, while Terminal is in front.
    @Published var focusedPid: Int?
    /// Set by AppDelegate; the tty check is skipped while nothing shows the dot.
    var hudVisible: () -> Bool = { true }
    @Published var subagents: [String: [Subagent]] = [:]
    @Published var defaultWindowTokens = 200_000

    // Last good usage result, cached across launches so the footer never
    // starts blank; a failed refresh keeps these and reports the error below.
    @Published var usage: [UsageLimit] = UsageCache.load()?.limits ?? []
    @Published var usageFetchedAt: Date? = UsageCache.load()?.fetchedAt
    @Published var usageError: String?
    /// Earliest time the next automatic usage fetch may run, after a 429.
    @Published var usageRetryAt: Date?
    private var usageBackoff: TimeInterval = 0

    // Mirrors of the prefs this model acts on, kept current by AppDelegate.
    var showPrompts = false
    var showContext = true
    var showUsage = false
    var showModel = false
    var warnFraction = 0.6
    var notifyContext = true
    var notifyWaiting = false
    var notifyFinished = false
    var driftRename = false
    var driftRenameAfter = 10

    private var warned: Set<String> = []
    private var notifiedWaiting: Set<String> = []
    // Drift renaming: typed prompts seen per session since its last naming.
    private var promptCounts: [String: Int] = [:]
    private var lastPromptIds: [String: String] = [:]
    /// Sessions the HUD just cleared or compacted: given a placeholder name
    /// now and auto-named again at their next prompt. Keyed by pid because
    /// /clear starts a new session id under the same terminal process.
    private struct FreshRename {
        var sessionId: String
        var promptId: String?
        let name: String
    }
    private var freshRenames: [Int: FreshRename] = [:]
    // For spotting clears and compactions done in the terminal itself.
    private var sessionIdByPid: [Int: String] = [:]
    private var lastCompactIds: [String: String] = [:]
    private var polling = false
    // Serialises the tty checks; they share this cache (a pid's tty never changes).
    private let focusQueue = DispatchQueue(label: "app.claude-agent-hud.focus", qos: .utility)
    private var ttyByPid: [Int: String] = [:]
    @Published private(set) var fetchingUsage = false
    private var usageTimer: Timer?


    func start() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshFocus()
        }
        poll()
        refreshUsage()
    }

    /// (Re)starts the periodic usage refresh, or stops it for manual-only.
    func scheduleUsageRefresh(everyMinutes minutes: Double) {
        usageTimer?.invalidate()
        guard minutes > 0 else { return }
        usageTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    // MARK: Session polling


    private func poll() {
        guard !polling else { return }
        polling = true
        let wantPrompt = showPrompts || driftRename  // read on main; the worker must not touch prefs mirrors
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = ClaudeCLI.fetchSessions()
            let defaultWindow = Self.readDefaultWindow()
            var details: [String: TranscriptDetail] = [:]
            if case .success(let sessions) = result {
                for session in sessions {
                    details[session.sessionId] = TranscriptParser.detail(
                        for: session.transcript,
                        wantPrompt: wantPrompt,
                        wantAssistantInfo: true  // context drives the compact action even when not shown
                    )
                }
            }
            DispatchQueue.main.async {
                self.apply(result, details: details, defaultWindow: defaultWindow)
                self.refreshFocus()
            }
        }
    }

    /// Updates `focusedPid`: one AppleScript call, only while Terminal is in
    /// front and the HUD is showing. Clicking the HUD's own windows keeps the
    /// mark; any other app drops it.
    private func refreshFocus() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front != Bundle.main.bundleIdentifier else { return }
        guard front == "com.apple.Terminal", hudVisible(), !sessions.isEmpty else {
            focusedPid = nil
            return
        }
        let sessions = self.sessions
        focusQueue.async { [weak self] in
            guard let self else { return }
            let focused = self.terminalSelectedPid(sessions)
            DispatchQueue.main.async { self.focusedPid = focused }
        }
    }

    /// The session running in Terminal.app's selected tab, matched by tty.
    private func terminalSelectedPid(_ sessions: [AgentSession]) -> Int? {
        let tty = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to tty of selected tab of front window"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func apply(
        _ result: Result<[AgentSession], ClaudeCLI.FetchError>,
        details: [String: TranscriptDetail],
        defaultWindow: Int
    ) {
        polling = false
        defaultWindowTokens = defaultWindow
        switch result {
        case .success(let sessions):
            self.sessions = sessions.filter { $0.name != AutoNamer.helperSessionName }
            SessionRegistry.reassert(self.sessions)
            lastPrompts = details.compactMapValues(\.prompt)
            contextTokens = details.compactMapValues(\.contextTokens)
            modelNames = details.compactMapValues(\.model)
            permissionModes = details.compactMapValues(\.permissionMode)
            efforts = details.compactMapValues(\.effort)
            activities = details.compactMapValues(\.activity)
            subagents = details.mapValues(\.subagents)
            let wasBusy = Set(busySince.keys)
            busySince = Self.transitionClocks(busySince, nowIn: sessions.ids(in: .busy))
            let liveIds = Set(sessions.map(\.sessionId))
            finishedAt = finishedAt.filter { liveIds.contains($0.key) }
            for session in sessions where session.state == .idle && wasBusy.contains(session.sessionId) {
                finishedAt[session.sessionId] = Date()
                if notifyFinished { Notifier.post("\(session.displayName) finished") }
            }
            idleSince = Self.transitionClocks(idleSince, nowIn: sessions.ids(in: .idle))
            dismissed.subtract(Set(sessions.filter { $0.state != .idle }.map(\.sessionId)))
            checkContextWarnings(sessions)
            checkWaitingNotifications(sessions)
            noteTerminalClearsAndCompacts(sessions, details: details)
            trackPrompts(sessions, details: details)
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.message
        }
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
            // Once per session for the life of this HUD run: a compact and
            // regrowth does not earn a second notification.
            guard fraction >= warnFraction, !warned.contains(session.sessionId) else { continue }
            warned.insert(session.sessionId)
            if notifyContext {
                notifyHighContext(session: session, percent: Int(fraction * 100))
            }
        }
    }

    // MARK: Drift renaming

    /// Counts newly typed prompts per session (the latest user entry's uuid
    /// changing between polls) and auto-names once the threshold is passed.
    private func trackPrompts(_ sessions: [AgentSession], details: [String: TranscriptDetail]) {
        renameFreshSessions(sessions, details: details)
        let live = Set(sessions.map(\.sessionId))
        promptCounts = promptCounts.filter { live.contains($0.key) }
        lastPromptIds = lastPromptIds.filter { live.contains($0.key) }
        for session in sessions {
            let id = session.sessionId
            guard let promptId = details[id]?.promptId else { continue }
            if let previous = lastPromptIds[id], previous != promptId {
                promptCounts[id, default: 0] += 1
            }
            lastPromptIds[id] = promptId
            guard driftRename, promptCounts[id, default: 0] >= driftRenameAfter,
                  !AutoNameStatus.shared.inFlight.contains(id) else { continue }
            promptCounts[id] = 0
            if !SessionRegistry.isUserNamed(session) {
                AutoNamer.rename(session)
            }
        }
    }

    func resetPromptCount(for sessionId: String) {
        promptCounts[sessionId] = 0
    }

    // MARK: Clear and compact

    func clearContext(_ session: AgentSession) {
        TerminalFocus.clearContext(pid: session.pid)
        noteCleared(session)
    }

    func compactContext(_ session: AgentSession) {
        TerminalFocus.compactContext(pid: session.pid)
        expectFreshName(session, suffix: "compacted")
    }

    func noteCleared(_ session: AgentSession) {
        expectFreshName(session, suffix: "cleared")
    }

    /// With drift renaming on, a cleared or compacted session gets a
    /// placeholder name straight away and a proper one at its next prompt.
    private func expectFreshName(_ session: AgentSession, suffix: String) {
        guard driftRename else { return }
        let name = AutoNamer.fallbackName(cwd: session.cwd) + "-" + suffix
        SessionRegistry.setName(name, for: session)
        freshRenames[session.pid] = FreshRename(
            sessionId: session.sessionId, promptId: lastPromptIds[session.sessionId], name: name
        )
    }

    /// A /clear typed in the terminal starts a new session id under the same
    /// pid; a /compact writes a boundary record to the transcript. Either is
    /// treated like the HUD's own clear or compact. Sessions the HUD already
    /// marked are left to renameFreshSessions.
    private func noteTerminalClearsAndCompacts(_ sessions: [AgentSession], details: [String: TranscriptDetail]) {
        let livePids = Set(sessions.map(\.pid))
        let liveIds = Set(sessions.map(\.sessionId))
        sessionIdByPid = sessionIdByPid.filter { livePids.contains($0.key) }
        lastCompactIds = lastCompactIds.filter { liveIds.contains($0.key) }
        for session in sessions {
            if let previous = sessionIdByPid[session.pid], previous != session.sessionId,
               freshRenames[session.pid] == nil {
                expectFreshName(session, suffix: "cleared")
            }
            sessionIdByPid[session.pid] = session.sessionId
            guard let compactId = details[session.sessionId]?.compactId else { continue }
            if let previous = lastCompactIds[session.sessionId], previous != compactId,
               freshRenames[session.pid] == nil {
                expectFreshName(session, suffix: "compacted")
            }
            lastCompactIds[session.sessionId] = compactId
        }
    }

    private func renameFreshSessions(_ sessions: [AgentSession], details: [String: TranscriptDetail]) {
        let livePids = Set(sessions.map(\.pid))
        freshRenames = freshRenames.filter { livePids.contains($0.key) }
        for session in sessions {
            guard var fresh = freshRenames[session.pid] else { continue }
            if fresh.sessionId != session.sessionId {
                // /clear started a new session in this terminal; carry the
                // placeholder over, as Claude Code may have re-derived the name.
                fresh.sessionId = session.sessionId
                fresh.promptId = nil
                SessionRegistry.setName(fresh.name, for: session)
                freshRenames[session.pid] = fresh
            }
            guard let promptId = details[session.sessionId]?.promptId, promptId != fresh.promptId,
                  !AutoNameStatus.shared.inFlight.contains(session.sessionId) else { continue }
            freshRenames[session.pid] = nil
            promptCounts[session.sessionId] = 0
            AutoNamer.rename(session)
        }
    }

    private func notifyHighContext(session: AgentSession, percent: Int) {
        Notifier.post("\(session.displayName) is at \(percent)% context, consider /compact")
    }

    /// Notifies once per stretch of waiting; re-arms when the session resumes.
    private func checkWaitingNotifications(_ sessions: [AgentSession]) {
        let waiting = sessions.ids(in: .waiting)
        if notifyWaiting {
            for session in sessions where session.state == .waiting
                && !notifiedWaiting.contains(session.sessionId) {
                Notifier.post("\(session.displayName) needs input")
            }
        }
        notifiedWaiting = waiting
    }

    // MARK: Usage limits

    /// Reads the Claude Code OAuth token from the Keychain and asks Anthropic's
    /// usage endpoint for the account's rate-limit status. Only runs while the
    /// toggle is on; the token is sent nowhere except api.anthropic.com.
    /// Automatic fetches respect the 429 backoff; a manual refresh (`force`)
    /// tries regardless, since the user chose to.
    func refreshUsage(force: Bool = false) {
        guard showUsage, !fetchingUsage else { return }
        if !force, let retryAt = usageRetryAt, retryAt > Date() { return }
        fetchingUsage = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetchUsageLimits()
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingUsage = false
                switch result {
                case .success(let limits):
                    self.usage = limits
                    self.usageFetchedAt = Date()
                    self.usageError = nil
                    UsageCache.save(limits: limits, fetchedAt: Date())
                    self.usageRetryAt = nil
                    self.usageBackoff = 0
                case .failure(let error):
                    self.usageError = error.reason
                    if error.rateLimited {
                        // The endpoint is known to keep returning 429 for a long
                        // time once tripped; back off 15m, 30m, 60m, capped at 2h,
                        // and never sooner than the server's retry-after.
                        self.usageBackoff = min(max(self.usageBackoff * 2, 15 * 60), 2 * 3600)
                        self.usageRetryAt = Date().addingTimeInterval(max(self.usageBackoff, error.retryAfter ?? 0))
                    }
                }
            }
        }
    }

    private struct UsageError: Error {
        let reason: String
        var rateLimited = false
        var retryAfter: TimeInterval?
    }

    private static func fetchUsageLimits() -> Result<[UsageLimit], UsageError> {
        let keychain = Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
        guard keychain.status == 0 else {
            // 36 = access denied by the user, 44 = item not found, 128 = user cancelled.
            return .failure(UsageError(reason: "keychain refused (\(keychain.status))"))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(keychain.output.utf8)) as? [String: Any],
              let oauth = parsed["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return .failure(UsageError(reason: "no sign-in token"))
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        var result: Result<[UsageLimit], UsageError> = .failure(UsageError(reason: "no response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                result = .failure(UsageError(reason: (error as? URLError)?.code == .notConnectedToInternet ? "offline" : "network error"))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if http.statusCode == 429 {
                    let retryAfter = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
                    result = .failure(UsageError(reason: "rate limited (429)", rateLimited: true, retryAfter: retryAfter))
                } else {
                    result = .failure(UsageError(reason: "http \(http.statusCode)"))
                }
                return
            }
            guard let data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let limits = body["limits"] as? [[String: Any]] else {
                result = .failure(UsageError(reason: "unexpected response"))
                return
            }
            result = .success(limits.compactMap(Self.usageLimit(from:)))
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
