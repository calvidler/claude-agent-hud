import Foundation
import Testing

@testable import AgentHUDCore

@Suite("Usage service")
struct UsageServiceTests {
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private func http(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: limit labels

    @Test("Known limit kinds get short labels")
    func knownKinds() {
        #expect(UsageService.limit(from: ["kind": "session", "percent": 12])?.label == "5h")
        #expect(UsageService.limit(from: ["kind": "weekly_all", "percent": 40])?.label == "week")
    }

    @Test("An unknown kind falls back to its model display name, then to the kind itself")
    func unknownKinds() {
        let scoped: [String: Any] = [
            "kind": "weekly_opus", "percent": 8,
            "scope": ["model": ["display_name": "Opus"]],
        ]
        #expect(UsageService.limit(from: scoped)?.label == "opus")
        #expect(UsageService.limit(from: ["kind": "weekly_opus", "percent": 8])?.label == "weekly_opus")
        #expect(UsageService.limit(from: ["percent": 8])?.label == "")
    }

    @Test("A limit without a percent is dropped; severity defaults to normal")
    func limitRequiresPercent() {
        #expect(UsageService.limit(from: ["kind": "session"]) == nil)
        #expect(UsageService.limit(from: ["kind": "session", "percent": 3])?.severity == "normal")
        #expect(UsageService.limit(from: ["kind": "session", "percent": 3, "severity": "warning"])?.severity == "warning")
    }

    // MARK: outcome

    @Test("A 200 with limits succeeds, skipping entries that are unusable")
    func successfulResponse() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "limits": [
                ["kind": "session", "percent": 12],
                ["kind": "weekly_all"],
                ["kind": "weekly_all", "percent": 40],
            ],
        ])
        let result = UsageService.outcome(data: body, response: http(200), error: nil)
        let limits = try #require(try result.get())
        #expect(limits.map(\.label) == ["5h", "week"])
        #expect(limits.map(\.percent) == [12, 40])
    }

    @Test("A 429 is flagged as rate limited and carries the server's retry-after")
    func rateLimited() {
        let result = UsageService.outcome(
            data: nil, response: http(429, headers: ["retry-after": "900"]), error: nil)
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.rateLimited)
        #expect(failure.retryAfter == 900)
        #expect(failure.reason == "rate limited (429)")
    }

    @Test("A 429 without a retry-after header is still flagged, with no interval")
    func rateLimitedWithoutHeader() {
        let result = UsageService.outcome(data: nil, response: http(429), error: nil)
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.rateLimited)
        #expect(failure.retryAfter == nil)
    }

    @Test("Other HTTP failures report their status and do not trigger backoff")
    func otherHTTPFailure() {
        let result = UsageService.outcome(data: nil, response: http(503), error: nil)
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.reason == "http 503")
        #expect(!failure.rateLimited)
    }

    @Test("Being offline is reported differently from a general network error")
    func networkErrors() {
        let offline = UsageService.outcome(
            data: nil, response: nil, error: URLError(.notConnectedToInternet))
        guard case .failure(let offlineFailure) = offline else { Issue.record("expected failure"); return }
        #expect(offlineFailure.reason == "offline")

        let other = UsageService.outcome(data: nil, response: nil, error: URLError(.timedOut))
        guard case .failure(let otherFailure) = other else { Issue.record("expected failure"); return }
        #expect(otherFailure.reason == "network error")
    }

    @Test("A 200 whose body is not the expected shape is reported, not crashed on")
    func malformedBody() {
        for data in [Data(), Data("not json".utf8), Data(#"{"nope":1}"#.utf8)] {
            let result = UsageService.outcome(data: data, response: http(200), error: nil)
            guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
            #expect(failure.reason == "unexpected response")
        }
    }
}
