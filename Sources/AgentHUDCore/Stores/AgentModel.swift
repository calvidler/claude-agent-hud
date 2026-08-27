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

    /// Mirror of the "Last prompt" pref, kept current by AppDelegate.
    var showPrompts = false

    let naming = SessionNaming()
    let alerts = SessionAlerts()
    private let focusTracker = TerminalFocusTracker()
    private var polling = false

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
    }

    // MARK: Session polling


    private func poll() {
        guard !polling else { return }
        polling = true
        let wantPrompt = showPrompts || naming.enabled  // read on main; the worker must not touch prefs mirrors
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

    /// Updates `focusedPid`, only while Terminal is in front and the HUD is
    /// showing. Clicking the HUD's own windows keeps the mark; any other app
    /// drops it.
    private func refreshFocus() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front != Bundle.main.bundleIdentifier else { return }
        guard front == "com.apple.Terminal", hudVisible(), !sessions.isEmpty else {
            focusedPid = nil
            return
        }
        focusTracker.selectedPid(among: sessions) { [weak self] pid in
            self?.focusedPid = pid
        }
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
                alerts.sessionFinished(session)
            }
            idleSince = Self.transitionClocks(idleSince, nowIn: sessions.ids(in: .idle))
            dismissed.subtract(Set(sessions.filter { $0.state != .idle }.map(\.sessionId)))
            alerts.checkContext(sessions, tokens: contextTokens, window: windowTokens(for:))
            alerts.checkWaiting(sessions)
            naming.observe(sessions, details: details)
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.message
        }
    }


    /// Keeps a start date per id: drops ids no longer present, stamps new ones now.
    static func transitionClocks(
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

    // MARK: Clear and compact

    func clearContext(_ session: AgentSession) {
        TerminalFocus.clearContext(pid: session.pid)
        noteCleared(session)
    }

    func compactContext(_ session: AgentSession) {
        TerminalFocus.compactContext(pid: session.pid)
        naming.expectFreshName(session, suffix: "compacted")
    }

    func noteCleared(_ session: AgentSession) {
        naming.expectFreshName(session, suffix: "cleared")
    }
}
