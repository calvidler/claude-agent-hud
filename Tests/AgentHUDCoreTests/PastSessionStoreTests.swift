import Foundation
import Testing

@testable import AgentHUDCore

@Suite("Past sessions")
struct PastSessionStoreTests {
    private let modified = Date(timeIntervalSince1970: 1_700_000_000)

    /// Writes `lines` as a transcript and reads it back the way the store does.
    private func read(_ lines: [String], id: String = "session-1") throws -> PastSession? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl").path
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        return PastSessionStore.read(path, id: id, modified: modified)
    }

    private func cwdLine(_ cwd: String = "/Users/dev/my-project") -> String {
        #"{"type":"user","cwd":"\#(cwd)","message":{"content":"start the work"}}"#
    }

    // MARK: name precedence

    @Test("A HUD or --name name beats /rename, which beats Claude Code's own title")
    func namePrecedence() throws {
        let ai = #"{"type":"ai-title","aiTitle":"derived"}"#
        let custom = #"{"type":"custom-title","customTitle":"renamed"}"#
        let agent = #"{"type":"agent-name","agentName":"hud-named"}"#

        #expect(try read([cwdLine(), ai, custom, agent])?.name == "hud-named")
        #expect(try read([cwdLine(), agent, custom, ai])?.name == "hud-named",
                "precedence is by kind, not by which line is last")
        #expect(try read([cwdLine(), ai, custom])?.name == "renamed")
        #expect(try read([cwdLine(), ai])?.name == "derived")
    }

    @Test("Within one kind the newest line wins")
    func newestLineWinsWithinKind() throws {
        let session = try read([
            cwdLine(),
            #"{"type":"agent-name","agentName":"first-name"}"#,
            #"{"type":"agent-name","agentName":"second-name"}"#,
        ])
        #expect(session?.name == "second-name")
    }

    @Test("An empty name is ignored rather than shown as a blank row")
    func emptyNameIgnored() throws {
        let session = try read([
            cwdLine(),
            #"{"type":"agent-name","agentName":""}"#,
            #"{"type":"custom-title","customTitle":"renamed"}"#,
        ])
        #expect(session?.name == "renamed")
    }

    // MARK: what makes a session worth listing

    @Test("A session with a prompt but no name is listed under its prompt")
    func promptOnlySession() throws {
        let session = try #require(try read([cwdLine()]))
        #expect(session.name == nil)
        #expect(session.firstPrompt == "start the work")
        #expect(session.displayName == "start the work")
        #expect(session.folder == "my-project")
    }

    @Test("A named session shows its name, not its first prompt")
    func nameBeatsPromptForDisplay() throws {
        let session = try #require(try read([cwdLine(), #"{"type":"agent-name","agentName":"hud-named"}"#]))
        #expect(session.displayName == "hud-named")
    }

    @Test("Nothing typed and never titled is not worth resuming, so it is skipped")
    func unnamedAndUnpromptedIsSkipped() throws {
        let meta = #"{"type":"user","cwd":"/Users/dev/my-project","isMeta":true,"message":{"content":"injected"}}"#
        #expect(try read([meta]) == nil)
    }

    @Test("A transcript with no cwd cannot be resumed, so it is skipped")
    func missingCwdIsSkipped() throws {
        #expect(try read([#"{"type":"user","message":{"content":"orphaned"}}"#]) == nil)
        #expect(try read([]) == nil)
    }

    @Test("A missing file is skipped rather than crashing the scan")
    func missingFileIsSkipped() {
        #expect(PastSessionStore.read("/nope/nowhere.jsonl", id: "x", modified: modified) == nil)
    }

    @Test("The first prompt is capped at 80 characters")
    func firstPromptIsCapped() throws {
        let long = String(repeating: "x", count: 200)
        let session = try read([#"{"type":"user","cwd":"/a/b","message":{"content":"\#(long)"}}"#])
        #expect(session?.firstPrompt?.count == 80)
    }

    @Test("The first typed prompt is kept, not the latest")
    func firstPromptNotLatest() throws {
        let session = try read([
            cwdLine(),
            #"{"type":"user","message":{"content":"a later prompt"}}"#,
        ])
        #expect(session?.firstPrompt == "start the work")
    }
}
