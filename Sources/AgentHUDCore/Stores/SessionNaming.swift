import Foundation

/// Decides when a session should be auto-named again.
///
/// Two triggers: enough new prompts typed since the last naming (drift), and a
/// session having just been cleared or compacted, which makes its old name
/// wrong immediately. Both only apply while drift renaming is on, and a name
/// the user set with /rename is never replaced.
final class SessionNaming {
    /// Mirrors of the prefs, kept current by AppDelegate.
    var enabled = false
    var renameAfter = 10

    // Typed prompts seen per session since its last naming.
    private var promptCounts: [String: Int] = [:]
    private var lastPromptIds: [String: String] = [:]

    /// A session the HUD just cleared or compacted: given a placeholder name
    /// now and auto-named again at its next prompt. Keyed by pid because
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

    /// Called on the main queue once per poll, after the session list is applied.
    func observe(_ sessions: [AgentSession], details: [String: TranscriptDetail]) {
        noteTerminalClearsAndCompacts(sessions, details: details)
        renameFreshSessions(sessions, details: details)
        trackPrompts(sessions, details: details)
    }

    func resetPromptCount(for sessionId: String) {
        promptCounts[sessionId] = 0
    }

    /// With drift renaming on, a cleared or compacted session gets a
    /// placeholder name straight away and a proper one at its next prompt.
    func expectFreshName(_ session: AgentSession, suffix: String) {
        guard enabled else { return }
        let name = AutoNamer.fallbackName(cwd: session.cwd) + "-" + suffix
        SessionRegistry.setName(name, for: session)
        freshRenames[session.pid] = FreshRename(
            sessionId: session.sessionId, promptId: lastPromptIds[session.sessionId], name: name
        )
    }

    /// Counts newly typed prompts per session (the latest user entry's uuid
    /// changing between polls) and auto-names once the threshold is passed.
    private func trackPrompts(_ sessions: [AgentSession], details: [String: TranscriptDetail]) {
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
            guard enabled, promptCounts[id, default: 0] >= renameAfter,
                  !AutoNameStatus.shared.inFlight.contains(id) else { continue }
            promptCounts[id] = 0
            if !SessionRegistry.isUserNamed(session) {
                AutoNamer.rename(session)
            }
        }
    }

    /// A /clear typed in the terminal starts a new session id under the same
    /// pid; a /compact writes a boundary record to the transcript. Either is
    /// treated like the HUD's own clear or compact. Sessions the HUD already
    /// marked are left to renameFreshSessions.
    private func noteTerminalClearsAndCompacts(
        _ sessions: [AgentSession], details: [String: TranscriptDetail]
    ) {
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
}
