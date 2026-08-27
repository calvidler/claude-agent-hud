import AppKit
import SwiftUI

// MARK: - Preferences

enum DisplayMode: String, CaseIterable, Codable, Identifiable {
    case overlay, window, dropdown
    var id: String { rawValue }

    var label: String {
        switch self {
        case .overlay: return "Overlay (always on top)"
        case .window: return "Window (can go behind)"
        case .dropdown: return "Menu bar dropdown"
        }
    }
}

enum RowOrder: String, CaseIterable, Codable, Identifiable {
    case attention, newest, oldest, name
    var id: String { rawValue }

    var label: String {
        switch self {
        case .attention: return "Needs attention first"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .name: return "By name"
        }
    }
}

struct RGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        (r, g, b, a) = (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }

    /// Resolves a dynamic system colour against the app's current light/dark
    /// appearance; without this the wrong variant is captured at launch.
    init(nsColor: NSColor) {
        var resolved = nsColor
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = nsColor.usingColorSpace(.sRGB) ?? .black
        }
        (r, g, b, a) = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent, 1)
    }
}

/// Property names are the persistence format (synthesized CodingKeys); renaming
/// one orphans its saved value.
struct Prefs: Codable, Equatable {
    var order = RowOrder.attention
    var background = RGBA(nsColor: .windowBackgroundColor)
    var backgroundOpacity = 0.8
    var text = RGBA(nsColor: .labelColor)
    var textOpacity = 0.9
    var deadAfterHours = 6.0
    var showLastPrompt = false
    var showContext = false
    var contextWarnPct = 0.6
    var showUsage = false
    var displayMode = DisplayMode.overlay
    var showInDock = false
    var showModel = false
    var showMode = true
    var showEffort = true
    var needsYou = false
    var skillLibrary = false
    var notifyHighContext = true
    var notifyWaiting = false
    var notifyFinished = false
    var usageRefreshMinutes = Prefs.manualUsageRefresh
    var driftRename = false
    var driftRenameAfter = 10.0

    /// Usage refresh interval meaning "no timer, refresh by hand only".
    static let manualUsageRefresh = 0.0
    static let usageRefreshChoices: [(label: String, minutes: Double)] = [
        ("5 minutes", 5), ("10 minutes", 10), ("15 minutes", 15), ("30 minutes", 30),
        ("1 hour", 60), ("2 hours", 120), ("Manual only", manualUsageRefresh),
    ]
}

// Tolerant decoding: a saved blob missing newly added fields keeps its known
// values and takes defaults for the rest, instead of resetting everything.
extension Prefs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        order = (try? c.decode(RowOrder.self, forKey: .order)) ?? d.order
        background = (try? c.decode(RGBA.self, forKey: .background)) ?? d.background
        backgroundOpacity = (try? c.decode(Double.self, forKey: .backgroundOpacity)) ?? d.backgroundOpacity
        text = (try? c.decode(RGBA.self, forKey: .text)) ?? d.text
        textOpacity = (try? c.decode(Double.self, forKey: .textOpacity)) ?? d.textOpacity
        deadAfterHours = (try? c.decode(Double.self, forKey: .deadAfterHours)) ?? d.deadAfterHours
        showLastPrompt = (try? c.decode(Bool.self, forKey: .showLastPrompt)) ?? d.showLastPrompt
        showContext = (try? c.decode(Bool.self, forKey: .showContext)) ?? d.showContext
        contextWarnPct = (try? c.decode(Double.self, forKey: .contextWarnPct)) ?? d.contextWarnPct
        showUsage = (try? c.decode(Bool.self, forKey: .showUsage)) ?? d.showUsage
        displayMode = (try? c.decode(DisplayMode.self, forKey: .displayMode)) ?? d.displayMode
        showInDock = (try? c.decode(Bool.self, forKey: .showInDock)) ?? d.showInDock
        showModel = (try? c.decode(Bool.self, forKey: .showModel)) ?? d.showModel
        showMode = (try? c.decode(Bool.self, forKey: .showMode)) ?? d.showMode
        showEffort = (try? c.decode(Bool.self, forKey: .showEffort)) ?? d.showEffort
        needsYou = (try? c.decode(Bool.self, forKey: .needsYou)) ?? d.needsYou
        skillLibrary = (try? c.decode(Bool.self, forKey: .skillLibrary)) ?? d.skillLibrary
        notifyHighContext = (try? c.decode(Bool.self, forKey: .notifyHighContext)) ?? d.notifyHighContext
        notifyWaiting = (try? c.decode(Bool.self, forKey: .notifyWaiting)) ?? d.notifyWaiting
        notifyFinished = (try? c.decode(Bool.self, forKey: .notifyFinished)) ?? d.notifyFinished
        // Snap older free-form minute values (and the old 61 = manual sentinel) to a choice.
        let savedRefresh = (try? c.decode(Double.self, forKey: .usageRefreshMinutes)) ?? d.usageRefreshMinutes
        if savedRefresh <= 0 || savedRefresh >= 61 {
            usageRefreshMinutes = Prefs.manualUsageRefresh
        } else {
            let timed = Prefs.usageRefreshChoices.map(\.minutes).filter { $0 > 0 }
            usageRefreshMinutes = timed.min { abs($0 - savedRefresh) < abs($1 - savedRefresh) } ?? d.usageRefreshMinutes
        }
        driftRename = (try? c.decode(Bool.self, forKey: .driftRename)) ?? d.driftRename
        driftRenameAfter = (try? c.decode(Double.self, forKey: .driftRenameAfter)) ?? d.driftRenameAfter
    }
}
