import Foundation

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
