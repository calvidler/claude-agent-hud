import Foundation
import Testing

@testable import AgentHUDCore

@Suite("Session naming")
struct SessionNamingTests {

    @Test("Names are lower-cased with every run of punctuation collapsed to one dash")
    func kebabCasing() {
        #expect(AutoNamer.kebabCased("Fix The Router") == "fix-the-router")
        #expect(AutoNamer.kebabCased("  spaces  and---dashes  ") == "spaces-and-dashes")
        #expect(AutoNamer.kebabCased("v2.1_final!") == "v2-1-final")
        #expect(AutoNamer.kebabCased("!!!") == "")
    }

    @Test("A usable suggestion is kebab-cased; anything outside 3-48 characters is rejected")
    func normalizeBounds() {
        #expect(AutoNamer.normalizeName("Billing Refactor") == "billing-refactor")
        #expect(AutoNamer.normalizeName("abc") == "abc")
        #expect(AutoNamer.normalizeName("ab") == nil)
        #expect(AutoNamer.normalizeName("") == nil)
        #expect(AutoNamer.normalizeName(String(repeating: "a", count: 48))?.count == 48)
        #expect(AutoNamer.normalizeName(String(repeating: "a", count: 49)) == nil)
    }

    @Test("A chatty reply that survives cleaning is still rejected on length")
    func normalizeRejectsProse() {
        let prose = "Sure! Here is a good name for this session: billing-refactor"
        #expect(AutoNamer.normalizeName(prose) == nil)
    }

    @Test("The fallback name is the project folder, kebab-cased")
    func fallbackName() {
        #expect(AutoNamer.fallbackName(cwd: "/Users/dev/My Project") == "my-project")
        #expect(AutoNamer.fallbackName(cwd: "/Users/dev/agent_hud.v2") == "agent-hud-v2")
    }

    @Test("A folder with nothing alphanumeric in it still yields a usable name")
    func fallbackNameForUnnamableFolder() {
        #expect(AutoNamer.fallbackName(cwd: "/Users/dev/...") == "untitled-session")
        #expect(AutoNamer.fallbackName(cwd: "/") == "untitled-session")
    }

    // MARK: transition clocks

    @Test("A newly seen session is stamped now; one that left the state is dropped")
    func transitionClocksTracksMembership() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let clocks = AgentModel.transitionClocks(["gone": old, "stays": old], nowIn: ["stays", "new"])
        #expect(Set(clocks.keys) == ["stays", "new"])
        #expect(clocks["stays"] == old, "an unbroken stretch keeps its original start")
        let newlyStamped = try? #require(clocks["new"])
        #expect(newlyStamped?.timeIntervalSinceNow ?? -99 > -5)
    }

    @Test("An empty set clears every clock")
    func transitionClocksEmpties() {
        #expect(AgentModel.transitionClocks(["a": Date()], nowIn: []).isEmpty)
    }
}
