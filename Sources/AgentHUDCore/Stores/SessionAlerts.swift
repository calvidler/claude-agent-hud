import Foundation

/// Decides which notifications to post, and suppresses repeats.
///
/// High context fires once per session for the life of this HUD run: a compact
/// and regrowth does not earn a second notification. Waiting and finished fire
/// once per episode and re-arm when the session moves on.
final class SessionAlerts {
    /// Mirrors of the prefs, kept current by AppDelegate.
    var showContext = true
    var warnFraction = 0.6
    var notifyContext = true
    var notifyWaiting = false
    var notifyFinished = false

    private var warned: Set<String> = []
    private var notifiedWaiting: Set<String> = []

    /// A session that went from working to idle since the last poll.
    func sessionFinished(_ session: AgentSession) {
        guard notifyFinished else { return }
        Notifier.post("\(session.displayName) finished")
    }

    /// `window` gives the context window to measure each session against, which
    /// depends on the model it is running.
    func checkContext(
        _ sessions: [AgentSession], tokens: [String: Int], window: (String) -> Int
    ) {
        guard showContext else { return }
        for session in sessions {
            guard let used = tokens[session.sessionId] else { continue }
            let fraction = Double(used) / Double(window(session.sessionId))
            guard fraction >= warnFraction, !warned.contains(session.sessionId) else { continue }
            warned.insert(session.sessionId)
            if notifyContext {
                Notifier.post("\(session.displayName) is at \(Int(fraction * 100))% context, consider /compact")
            }
        }
    }

    func checkWaiting(_ sessions: [AgentSession]) {
        let waiting = sessions.ids(in: .waiting)
        if notifyWaiting {
            for session in sessions where session.state == .waiting
                && !notifiedWaiting.contains(session.sessionId) {
                Notifier.post("\(session.displayName) needs input")
            }
        }
        notifiedWaiting = waiting
    }
}
