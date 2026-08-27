import Foundation
import Testing

@testable import AgentHUDCore

@Suite("Preferences")
struct PrefsTests {
    private func decode(_ json: [String: Any]) throws -> Prefs {
        try JSONDecoder().decode(Prefs.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("A saved blob keeps its known values and takes defaults for fields it predates")
    func tolerantDecoding() throws {
        let prefs = try decode(["showUsage": true, "deadAfterHours": 2.5])
        #expect(prefs.showUsage)
        #expect(prefs.deadAfterHours == 2.5)
        #expect(prefs.order == Prefs().order, "an absent field falls back to its default")
        #expect(prefs.showMode == Prefs().showMode)
    }

    @Test("A field saved with the wrong type falls back rather than resetting everything")
    func wrongTypeFallsBack() throws {
        let prefs = try decode(["showUsage": true, "deadAfterHours": "not a number"])
        #expect(prefs.showUsage, "the sound fields survive")
        #expect(prefs.deadAfterHours == Prefs().deadAfterHours)
    }

    @Test("An empty blob decodes to the defaults")
    func emptyBlob() throws {
        #expect(try decode([:]) == Prefs())
    }

    @Test("Every offered usage refresh interval survives a save and reload")
    func everyRefreshChoiceRoundTrips() throws {
        for choice in Prefs.usageRefreshChoices {
            var prefs = Prefs()
            prefs.usageRefreshMinutes = choice.minutes
            let reloaded = try JSONDecoder().decode(Prefs.self, from: JSONEncoder().encode(prefs))
            #expect(
                reloaded.usageRefreshMinutes == choice.minutes,
                "\(choice.label) came back as \(reloaded.usageRefreshMinutes)")
        }
    }

    @Test("A free-form interval from an older build snaps to the nearest offered one")
    func legacyIntervalsSnap() throws {
        #expect(try decode(["usageRefreshMinutes": 7.0]).usageRefreshMinutes == 5)
        #expect(try decode(["usageRefreshMinutes": 20.0]).usageRefreshMinutes == 15)
        #expect(try decode(["usageRefreshMinutes": 100.0]).usageRefreshMinutes == 120)
    }

    @Test("Values that meant manual-only still mean manual-only")
    func legacyManualSentinels() throws {
        #expect(try decode(["usageRefreshMinutes": 0.0]).usageRefreshMinutes == Prefs.manualUsageRefresh)
        #expect(try decode(["usageRefreshMinutes": -1.0]).usageRefreshMinutes == Prefs.manualUsageRefresh)
        #expect(try decode(["usageRefreshMinutes": 61.0]).usageRefreshMinutes == Prefs.manualUsageRefresh,
                "61 was the old manual sentinel")
        #expect(try decode(["usageRefreshMinutes": 999.0]).usageRefreshMinutes == Prefs.manualUsageRefresh,
                "longer than anything now offered")
    }

    @Test("Colours survive a round trip")
    func colourRoundTrip() throws {
        var prefs = Prefs()
        prefs.background = RGBA(color: .red)
        let reloaded = try JSONDecoder().decode(Prefs.self, from: JSONEncoder().encode(prefs))
        #expect(reloaded.background == prefs.background)
    }
}
