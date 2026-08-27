import Foundation
import Testing

@testable import AgentHUDCore

@Suite("Transcript parser")
struct TranscriptParserTests {

    // MARK: stringValues

    @Test("Finds every occurrence of a key, in order")
    func stringValuesFindsAll() {
        let line: Substring = #"{"a":"one","b":2,"a":"two"}"#
        #expect(TranscriptParser.stringValues(of: "a", in: line) == ["one", "two"])
    }

    @Test("A missing key yields no values")
    func stringValuesMissingKey() {
        #expect(TranscriptParser.stringValues(of: "nope", in: #"{"a":"one"}"#).isEmpty)
    }

    @Test("Only a numeric value for the key yields nothing, since it scans for a quote")
    func stringValuesNumericValue() {
        #expect(TranscriptParser.stringValues(of: "b", in: #"{"b":2}"#).isEmpty)
    }

    @Test("requiredPrefix filters out ids belonging to other keys")
    func stringValuesRequiredPrefix() {
        let line: Substring = #"{"id":"msg_1","id":"toolu_9"}"#
        #expect(TranscriptParser.stringValues(of: "id", in: line, requiredPrefix: "toolu_") == ["toolu_9"])
    }

    // MARK: typedPrompt

    @Test("Plain string content is the prompt")
    func typedPromptFromString() {
        #expect(TranscriptParser.typedPrompt(from: ["content": "  fix the router  "]) == "fix the router")
    }

    @Test("Text blocks are joined; non-text blocks are ignored")
    func typedPromptFromBlocks() {
        let message: [String: Any] = ["content": [
            ["type": "text", "text": "fix"],
            ["type": "image"],
            ["type": "text", "text": "the router"],
        ]]
        #expect(TranscriptParser.typedPrompt(from: message) == "fix the router")
    }

    @Test("A message carrying a tool result is not a typed prompt")
    func typedPromptRejectsToolResult() {
        let message: [String: Any] = ["content": [
            ["type": "tool_result", "content": "ok"],
            ["type": "text", "text": "looks fine"],
        ]]
        #expect(TranscriptParser.typedPrompt(from: message) == nil)
    }

    @Test("System and command wrappers, which start with a tag, are not typed prompts")
    func typedPromptRejectsWrappers() {
        #expect(TranscriptParser.typedPrompt(from: ["content": "<command-name>/clear</command-name>"]) == nil)
        #expect(TranscriptParser.typedPrompt(from: ["content": "   "]) == nil)
        #expect(TranscriptParser.typedPrompt(from: [:]) == nil)
    }

    @Test("Newlines are flattened and the prompt is capped at 140 characters")
    func typedPromptFlattensAndTruncates() {
        #expect(TranscriptParser.typedPrompt(from: ["content": "one\ntwo"]) == "one two")
        let long = String(repeating: "x", count: 200)
        #expect(TranscriptParser.typedPrompt(from: ["content": long])?.count == 140)
    }

    // MARK: contextTokens

    @Test("Context is input plus both cache fields plus output")
    func contextTokensSums() {
        let usage: [String: Any] = [
            "input_tokens": 10, "cache_read_input_tokens": 100,
            "cache_creation_input_tokens": 1_000, "output_tokens": 5,
        ]
        #expect(TranscriptParser.contextTokens(from: usage) == 1_115)
    }

    @Test("No input tokens means no usable figure, even when output is present")
    func contextTokensNeedsInput() {
        #expect(TranscriptParser.contextTokens(from: ["output_tokens": 5]) == nil)
        #expect(TranscriptParser.contextTokens(from: [:]) == nil)
    }

    // MARK: activityText

    @Test("Activity names the tool and its file, capped at 24 characters")
    func activityTextNamesFile() {
        #expect(TranscriptParser.activityText(tool: "Read", input: ["file_path": "/a/b/router.tsx"]) == "reading router.tsx")
        #expect(TranscriptParser.activityText(tool: "Write", input: ["file_path": "/a/b/router.tsx"]) == "editing router.tsx")
        let long = "/a/" + String(repeating: "n", count: 40) + ".ts"
        #expect(TranscriptParser.activityText(tool: "Edit", input: ["file_path": long]) == "editing " + String(repeating: "n", count: 24))
    }

    @Test("Tools without a file get a bare verb, and unknown tools fall back to working")
    func activityTextWithoutFile() {
        #expect(TranscriptParser.activityText(tool: "Bash", input: [:]) == "running")
        #expect(TranscriptParser.activityText(tool: "Grep", input: [:]) == "searching")
        #expect(TranscriptParser.activityText(tool: "Skill", input: ["skill": "verify"]) == "/verify")
        #expect(TranscriptParser.activityText(tool: "Skill", input: [:]) == "/skill")
        #expect(TranscriptParser.activityText(tool: "SomethingNew", input: [:]) == "working")
        #expect(TranscriptParser.activityText(tool: "Read", input: [:]) == "reading ")
    }

    // MARK: detail, against a transcript on disk

    /// Writes `lines` as a transcript and returns a ref pointing at it.
    private func transcript(_ lines: [String]) throws -> TranscriptRef {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        let ref = TranscriptRef(cwd: cwd, sessionId: "session-1")
        try FileManager.default.createDirectory(
            atPath: (ref.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: ref.path, atomically: true, encoding: .utf8)
        return ref
    }

    @Test("A missing transcript yields an empty detail rather than failing")
    func detailOfMissingFile() {
        let detail = TranscriptParser.detail(
            for: TranscriptRef(cwd: "/nope/nowhere", sessionId: "x"),
            wantPrompt: true, wantAssistantInfo: true)
        #expect(detail.prompt == nil)
        #expect(detail.contextTokens == nil)
        #expect(detail.subagents.isEmpty)
    }

    @Test("Reads the newest prompt, model, context, mode and effort")
    func detailReadsNewest() throws {
        let ref = try transcript([
            #"{"type":"user","uuid":"u1","message":{"content":"first go","permissionMode":"plan"}}"#,
            #"{"type":"user","uuid":"u2","message":{"content":"second go","permissionMode":"auto"}}"#,
            #"{"type":"assistant","effort":"high","message":{"model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":10}}}"#,
        ])
        let detail = TranscriptParser.detail(for: ref, wantPrompt: true, wantAssistantInfo: true)
        #expect(detail.prompt == "second go")
        #expect(detail.promptId == "u2")
        #expect(detail.model == "claude-opus-5")
        #expect(detail.contextTokens == 1_010)
        #expect(detail.permissionMode == "auto")
        #expect(detail.effort == "high")
    }

    @Test("Meta and compact-summary entries are never treated as typed prompts")
    func detailSkipsMetaEntries() throws {
        let ref = try transcript([
            #"{"type":"user","uuid":"u1","message":{"content":"real prompt"}}"#,
            #"{"type":"user","uuid":"u2","isMeta":true,"message":{"content":"injected context"}}"#,
            #"{"type":"user","uuid":"u3","isCompactSummary":true,"message":{"content":"summary"}}"#,
        ])
        let detail = TranscriptParser.detail(for: ref, wantPrompt: true, wantAssistantInfo: false)
        #expect(detail.prompt == "real prompt")
        #expect(detail.promptId == "u1")
    }

    @Test("wantPrompt off skips prompt reading but still reports usage")
    func detailRespectsWantFlags() throws {
        let ref = try transcript([
            #"{"type":"user","uuid":"u1","message":{"content":"a prompt"}}"#,
            #"{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":7}}}"#,
        ])
        let detail = TranscriptParser.detail(for: ref, wantPrompt: false, wantAssistantInfo: true)
        #expect(detail.prompt == nil)
        #expect(detail.contextTokens == 7)
    }

    @Test("Subagents are listed oldest first, marked done once their result arrives")
    func detailPairsSubagents() throws {
        let ref = try transcript([
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"description":"first task"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Agent","input":{"description":"second task"}}]}}"#,
        ])
        let detail = TranscriptParser.detail(for: ref, wantPrompt: false, wantAssistantInfo: false)
        #expect(detail.subagents.map(\.description) == ["first task", "second task"])
        #expect(detail.subagents.map(\.running) == [false, true])
    }

    @Test("The latest tool call drives the activity, and reads as thinking once its result is back")
    func detailReportsActivity() throws {
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_9","name":"Edit","input":{"file_path":"/x/router.tsx"}}]}}"#
        #expect(TranscriptParser.detail(for: try transcript([call]),
                                       wantPrompt: false, wantAssistantInfo: false).activity == "editing router.tsx")

        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_9"}]}}"#
        #expect(TranscriptParser.detail(for: try transcript([call, result]),
                                       wantPrompt: false, wantAssistantInfo: false).activity == "thinking")
    }

    @Test("The newest compact boundary is reported, so a repeat compact is detectable")
    func detailReportsCompactBoundary() throws {
        let ref = try transcript([
            #"{"type":"system","subtype":"compact_boundary","uuid":"boundary-1"}"#,
            #"{"type":"system","subtype":"compact_boundary","uuid":"boundary-2"}"#,
        ])
        #expect(TranscriptParser.detail(for: ref, wantPrompt: false, wantAssistantInfo: false).compactId == "boundary-2")
    }

    // MARK: readTail

    @Test("readTail returns only the last bytes of a long transcript")
    func readTailIsBounded() throws {
        let ref = try transcript([String(repeating: "a", count: 5_000), "tail line"])
        let tail = try #require(TranscriptParser.readTail(of: ref, bytes: 20))
        #expect(tail == String(repeating: "a", count: 10) + "\ntail line")
    }
}
