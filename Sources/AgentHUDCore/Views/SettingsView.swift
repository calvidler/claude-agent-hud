import AppKit
import SwiftUI

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var tab = Tab.general
    @State private var resetToken = 0

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case details = "Details"
        case appearance = "Appearance"
        case notifications = "Notifications"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 18) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .general: generalTab
            case .details: detailsTab
            case .appearance: appearanceTab
            case .notifications: notificationsTab
            }
        }
        .padding(20)
        .frame(width: 440)
        .id(resetToken)
    }

    // MARK: Tabs

    private var generalTab: some View {
        VStack(spacing: 16) {
            SettingsSection {
                SettingsRow("Display") {
                    Picker("", selection: $settings.prefs.displayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                SettingsRow("Show in Dock") { SettingsSwitch(isOn: $settings.prefs.showInDock) }
            }
            SettingsSection(footer: "Right-click a session to add a skill from the library to its project (.claude/skills). It starts with a few; add your own as folders holding a SKILL.md.") {
                SettingsRow("Skill library") { SettingsSwitch(isOn: $settings.prefs.skillLibrary) }
                SettingsRow("Library folder") {
                    Button("Open") { SkillLibrary.reveal() }
                        .controlSize(.small)
                }
                .disabled(!settings.prefs.skillLibrary)
            }
            SettingsSection(footer: "⌥⌘A shows or hides the panel. Sessions idle longer than this are marked dead and can be cleared from the list.") {
                SettingsRow("Row order") {
                    Picker("", selection: $settings.prefs.order) {
                        ForEach(RowOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                SettingsRow("Dead after \(deadAfterLabel)") {
                    Slider(value: stepped($settings.prefs.deadAfterHours, by: 0.5), in: 0.5...6)
                        .frame(width: 160)
                }
            }
            Button("Reset all settings") {
                NSColorPanel.shared.close()
                settings.prefs = Prefs()
                resetToken += 1  // rebuild the view so colour swatches refresh
            }
            .controlSize(.small)
        }
    }

    private var detailsTab: some View {
        VStack(spacing: 16) {
            SettingsSection(header: "Show per session") {
                SettingsRow("Last prompt") { SettingsSwitch(isOn: $settings.prefs.showLastPrompt) }
                SettingsRow("Model") { SettingsSwitch(isOn: $settings.prefs.showModel) }
                SettingsRow("Mode (plan, auto, …)") { SettingsSwitch(isOn: $settings.prefs.showMode) }
                SettingsRow("Effort (low, high, …)") { SettingsSwitch(isOn: $settings.prefs.showEffort) }
                SettingsRow("Context %") { SettingsSwitch(isOn: $settings.prefs.showContext) }
                SettingsRow("Warn above \(Int((settings.prefs.contextWarnPct * 100).rounded()))%") {
                    Slider(value: stepped($settings.prefs.contextWarnPct, by: 0.05), in: 0.3...0.9)
                        .frame(width: 160)
                }
                .disabled(!settings.prefs.showContext)
            }
            SettingsSection(
                header: "Account",
                footer: "Reads your Claude Code sign-in token from the Keychain to ask Anthropic for your limits. The token is sent only to api.anthropic.com. Anthropic rate-limits this endpoint hard (429); the HUD keeps the last numbers and backs off, so a slow refresh or manual only is the safe choice."
            ) {
                SettingsRow("Usage left") { SettingsSwitch(isOn: $settings.prefs.showUsage) }
                SettingsRow("Refresh") {
                    Picker("", selection: $settings.prefs.usageRefreshMinutes) {
                        ForEach(Prefs.usageRefreshChoices, id: \.minutes) { choice in
                            Text(choice.label).tag(choice.minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                .disabled(!settings.prefs.showUsage)
            }
            SettingsSection(
                header: "Auto-name",
                footer: "Renames a session automatically once this many new prompts have been typed since it was last named. Names you set with /rename are never replaced."
            ) {
                SettingsRow("Rename as work drifts") { SettingsSwitch(isOn: $settings.prefs.driftRename) }
                SettingsRow("After \(Int(settings.prefs.driftRenameAfter)) prompts") {
                    Slider(value: stepped($settings.prefs.driftRenameAfter, by: 1), in: 3...30)
                        .frame(width: 160)
                }
                .disabled(!settings.prefs.driftRename)
            }
        }
    }

    private var appearanceTab: some View {
        VStack(spacing: 16) {
            SettingsSection(header: "Background") {
                SettingsRow("Colour") {
                    ColorPicker("", selection: backgroundColor, supportsOpacity: false).labelsHidden()
                }
                SettingsRow("Opacity") {
                    Slider(value: $settings.prefs.backgroundOpacity, in: 0.05...1).frame(width: 160)
                }
            }
            SettingsSection(header: "Text") {
                SettingsRow("Colour") {
                    ColorPicker("", selection: textColor, supportsOpacity: false).labelsHidden()
                }
                SettingsRow("Opacity") {
                    Slider(value: $settings.prefs.textOpacity, in: 0.2...1).frame(width: 160)
                }
            }
        }
    }

    private var notificationsTab: some View {
        SettingsSection(
            header: "Notify when a session is",
            footer: "High context uses the warn threshold from Details and needs Context % on, and fires once per session. Waiting and finished fire once per episode."
        ) {
            SettingsRow("Waiting for input") { SettingsSwitch(isOn: $settings.prefs.notifyWaiting) }
            SettingsRow("Finished working") { SettingsSwitch(isOn: $settings.prefs.notifyFinished) }
            SettingsRow("High context") { SettingsSwitch(isOn: $settings.prefs.notifyHighContext) }
        }
    }

    // MARK: Helpers

    private var deadAfterLabel: String {
        let hours = settings.prefs.deadAfterHours
        if hours < 1 { return "\(Int(hours * 60))m" }
        return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    /// A slider binding that snaps to a step without drawing tick marks.
    private func stepped(_ binding: Binding<Double>, by step: Double) -> Binding<Double> {
        Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = ($0 / step).rounded() * step }
        )
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { settings.prefs.background.color },
            set: { settings.prefs.background = RGBA(color: $0) }
        )
    }

    private var textColor: Binding<Color> {
        Binding(
            get: { settings.prefs.text.color },
            set: { settings.prefs.text = RGBA(color: $0) }
        )
    }
}
