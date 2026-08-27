import Combine
import Foundation

/// The account's rate-limit status, from Anthropic's usage endpoint.
///
/// Reads the Claude Code OAuth token from the Keychain and sends it nowhere
/// except api.anthropic.com, and only while the "Usage left" toggle is on.
/// The last good result is cached across launches so the footer never starts
/// blank; a failed refresh keeps those numbers and reports the error.
final class UsageService: ObservableObject {
    @Published private(set) var limits: [UsageLimit]
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var error: String?
    /// Earliest time the next automatic fetch may run, after a 429.
    @Published private(set) var retryAt: Date?
    @Published private(set) var fetching = false

    /// Mirrors the pref; nothing is fetched while this is off.
    var enabled = false

    private var backoff: TimeInterval = 0
    private var timer: Timer?

    init() {
        let cached = UsageCache.load()
        limits = cached?.limits ?? []
        fetchedAt = cached?.fetchedAt
    }

    /// (Re)starts the periodic refresh, or stops it for manual-only.
    func schedule(everyMinutes minutes: Double) {
        timer?.invalidate()
        guard minutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Automatic fetches respect the 429 backoff; a manual refresh (`force`)
    /// tries regardless, since the user chose to.
    func refresh(force: Bool = false) {
        guard enabled, !fetching else { return }
        if !force, let retryAt, retryAt > Date() { return }
        fetching = true
        Self.fetch { [weak self] result in
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    private func apply(_ result: Result<[UsageLimit], UsageError>) {
        fetching = false
        switch result {
        case .success(let limits):
            let now = Date()
            self.limits = limits
            fetchedAt = now
            error = nil
            UsageCache.save(limits: limits, fetchedAt: now)
            retryAt = nil
            backoff = 0
        case .failure(let failure):
            error = failure.reason
            if failure.rateLimited {
                // The endpoint is known to keep returning 429 for a long time
                // once tripped; back off 15m, 30m, 60m, capped at 2h, and never
                // sooner than the server's retry-after.
                backoff = min(max(backoff * 2, 15 * 60), 2 * 3600)
                retryAt = Date().addingTimeInterval(max(backoff, failure.retryAfter ?? 0))
            }
        }
    }

    struct UsageError: Error {
        let reason: String
        var rateLimited = false
        var retryAfter: TimeInterval?
    }

    /// Answers on URLSession's queue, or on a background queue when it never
    /// gets as far as the request.
    private static func fetch(completion: @escaping (Result<[UsageLimit], UsageError>) -> Void) {
        // The Keychain read shells out, so it must not run on the main queue.
        DispatchQueue.global(qos: .utility).async {
            let keychain = Shell.run(
                "/usr/bin/security",
                ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            )
            guard keychain.status == 0 else {
                // 36 = access denied by the user, 44 = item not found, 128 = user cancelled.
                completion(.failure(UsageError(reason: "keychain refused (\(keychain.status))")))
                return
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(keychain.output.utf8)) as? [String: Any],
                  let oauth = parsed["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String else {
                completion(.failure(UsageError(reason: "no sign-in token")))
                return
            }

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { data, response, error in
                completion(Self.outcome(data: data, response: response, error: error))
            }.resume()
        }
    }

    /// Turns one HTTP outcome into limits or a reason to show.
    static func outcome(
        data: Data?, response: URLResponse?, error: Error?
    ) -> Result<[UsageLimit], UsageError> {
        if let error {
            let offline = (error as? URLError)?.code == .notConnectedToInternet
            return .failure(UsageError(reason: offline ? "offline" : "network error"))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            guard http.statusCode == 429 else {
                return .failure(UsageError(reason: "http \(http.statusCode)"))
            }
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            return .failure(UsageError(reason: "rate limited (429)", rateLimited: true, retryAfter: retryAfter))
        }
        guard let data,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = body["limits"] as? [[String: Any]] else {
            return .failure(UsageError(reason: "unexpected response"))
        }
        return .success(limits.compactMap(limit(from:)))
    }

    static func limit(from limit: [String: Any]) -> UsageLimit? {
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

enum UsageCache {
    private struct Entry: Codable {
        let limits: [UsageLimit]
        let fetchedAt: Date
    }

    static func load() -> (limits: [UsageLimit], fetchedAt: Date)? {
        guard let data = UserDefaults.standard.data(forKey: "usageCache"),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return (entry.limits, entry.fetchedAt)
    }

    static func save(limits: [UsageLimit], fetchedAt: Date) {
        if let data = try? JSONEncoder().encode(Entry(limits: limits, fetchedAt: fetchedAt)) {
            UserDefaults.standard.set(data, forKey: "usageCache")
        }
    }
}
