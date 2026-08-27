import Foundation
import Testing

@testable import AgentHUDCore

@Suite("Session model")
struct SessionModelTests {
    private func session(
        name: String? = nil, cwd: String = "/Users/dev/my-project",
        status: String = "idle", sessionId: String = "abc-123"
    ) -> AgentSession {
        AgentSession(
            pid: 42, cwd: cwd, startedAt: 1_700_000_000, sessionId: sessionId,
            name: name, status: status, waitingFor: nil
        )
    }

    @Test("Transcript path replaces every non-alphanumeric in the cwd with a dash")
    func transcriptPathMunging() {
        let ref = TranscriptRef(cwd: "/Users/dev/my_project.v2", sessionId: "abc-123")
        #expect(ref.path == NSHomeDirectory() + "/.claude/projects/-Users-dev-my-project-v2/abc-123.jsonl")
    }

    @Test("Display name falls back to the folder when the session has no name")
    func displayNameFallback() {
        #expect(session(name: "billing-refactor").displayName == "billing-refactor")
        #expect(session(name: nil).displayName == "my-project")
        #expect(session(name: "").displayName == "my-project")
    }

    @Test("Unknown status decodes as busy rather than dropping the session")
    func unknownStatus() {
        #expect(session(status: "waiting").state == .waiting)
        #expect(session(status: "something-new").state == .busy)
    }

    @Test("Attention rank orders waiting before busy before idle")
    func attentionRank() {
        let ordered = [SessionStatus.idle, .waiting, .busy].sorted { $0.rank < $1.rank }
        #expect(ordered == [.waiting, .busy, .idle])
    }
}
