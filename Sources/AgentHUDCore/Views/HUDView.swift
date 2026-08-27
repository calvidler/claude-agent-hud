import AppKit
import SwiftUI

// MARK: - HUD view

struct HUDView: View {
    @ObservedObject var model: AgentModel
    @ObservedObject var settings: Settings
    @ObservedObject var usage: UsageService
    @ObservedObject private var naming = AutoNameStatus.shared
    let onClose: () -> Void
    let onSettings: () -> Void
    let onPastSessions: () -> Void
    @State private var hoveredId: String?
    @State private var expandedIds: Set<String> = []

    private static let deadDot = Color(red: 0.75, green: 0.2, blue: 0.2)
    private static let closeDot = Color(red: 1, green: 0.37, blue: 0.34)

    var body: some View {
        content
            .background(
                settings.prefs.background.color.opacity(settings.prefs.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .padding(6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            topBar
            divider
            if let message = model.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
            } else if model.sessions.isEmpty {
                Text("No agents running")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
            } else {
                ForEach(ordered) { session in
                    row(session)
                    if expandedIds.contains(session.sessionId) {
                        subagentRows(session)
                    }
                }
            }
            if settings.prefs.showUsage {
                divider
                usageFooter
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Circle()
                    .fill(Self.closeDot)
                    .frame(width: 9, height: 9)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Claude Agent HUD")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(secondaryText)
            Spacer()
            Button { settings.prefs.needsYou.toggle() } label: {
                Image(systemName: settings.prefs.needsYou ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 8))
                    .foregroundStyle(settings.prefs.needsYou ? primaryText : secondaryText)
            }
            .buttonStyle(.plain)
            .help("Needs you: sessions waiting on you first, the rest dimmed")
            Button(action: onPastSessions) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 8))
                    .foregroundStyle(secondaryText)
            }
            .buttonStyle(.plain)
            .help("Past sessions")
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 2)
    }

    private var divider: some View {
        Rectangle()
            .fill(primaryText.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 2)
    }

    private var usageFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                if usage.limits.isEmpty {
                    Text(usage.fetching ? "fetching usage…" : "usage")
                        .font(.system(size: 9))
                        .foregroundStyle(secondaryText)
                }
                ForEach(usage.limits) { limit in
                    Text("\(limit.label) \(limit.percent)%")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(usageColor(limit))
                }
                Spacer(minLength: 0)
                if usage.fetching {
                    ProgressView().controlSize(.mini)
                } else {
                    rowAction("arrow.clockwise", tint: secondaryText, help: usageAgeText.map { "Refresh usage now (\($0))" } ?? "Refresh usage now") {
                        usage.refresh(force: true)
                    }
                }
            }
            if let error = usage.error, !usage.fetching {
                Text(usageErrorText(error))
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 1)
    }

    /// One quiet line, e.g. "refresh failed: rate limited (429), retry in 14m".
    private func usageErrorText(_ error: String) -> String {
        guard let retryAt = usage.retryAt, retryAt > model.now else { return "refresh failed: \(error)" }
        return "refresh failed: \(error), retry in \(max(1, Int(retryAt.timeIntervalSince(model.now) / 60)))m"
    }

    /// "updated 12m ago", for the numbers currently on screen.
    private var usageAgeText: String? {
        guard let fetchedAt = usage.fetchedAt else { return nil }
        let minutes = Int(model.now.timeIntervalSince(fetchedAt) / 60)
        if minutes < 1 { return "updated just now" }
        if minutes < 60 { return "updated \(minutes)m ago" }
        return "updated \(minutes / 60)h ago"
    }

    // MARK: Rows

    private func row(_ session: AgentSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(model.focusedPid == session.pid ? Color.blue
                      : isDead(session) ? Self.deadDot : statusColor(session.state))
                .frame(width: 7, height: 7)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    if justFinished(session) {
                        Text("just finished")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(secondaryText)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(primaryText.opacity(0.08)))
                    }
                }
                if settings.prefs.showLastPrompt,
                   let prompt = model.lastPrompts[session.sessionId] {
                    Text(prompt)
                        .font(.system(size: 10))
                        .italic()
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Text(subtitle(session))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(session.state == .waiting ? Color.orange : secondaryText)
                    .lineLimit(1)
            }
            .allowsHitTesting(false)
            Spacer(minLength: 0)
            if settings.prefs.showContext, !isDead(session),
               let percent = contextPercent(session) {
                Text("\(percent)%")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(contextColor(percent))
                    .allowsHitTesting(false)
            }
            // Row action: dead rows offer clear (/clear); idle rows past the
            // context threshold offer compact (/compact). Everything else is
            // in the right-click menu.
            if naming.inFlight.contains(session.sessionId) {
                ProgressView()
                    .controlSize(.mini)
                    .allowsHitTesting(false)
            } else if isDead(session) {
                rowAction("eraser.fill", tint: secondaryText, help: "Clear this session's context (/clear)") {
                    model.clearContext(session)
                }
            } else if needsCompact(session) {
                rowAction("arrow.down.right.and.arrow.up.left", tint: primaryText, help: "Compact this session's context (/compact)") {
                    model.compactContext(session)
                }
            }
            if !(model.subagents[session.sessionId] ?? []).isEmpty {
                Button {
                    toggleExpanded(session.sessionId)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .rotationEffect(.degrees(expandedIds.contains(session.sessionId) ? 90 : 0))
                }
                .buttonStyle(.plain)
                .help("Show subagents")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .opacity(settings.prefs.needsYou && !needsYou(session) ? 0.4 : 1)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(hoveredId == session.id ? 0.09 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredId = session.id
                NSCursor.pointingHand.set()
            } else {
                if hoveredId == session.id { hoveredId = nil }
                NSCursor.arrow.set()
            }
        }
        .onTapGesture {
            TerminalFocus.focus(pid: session.pid)
        }
        .contextMenu {
            Button("Jump to terminal") { TerminalFocus.focus(pid: session.pid) }
            Button("Fork") {
                TerminalFocus.resume(
                    cwd: session.cwd, sessionId: session.sessionId, displayName: session.displayName, fork: true)
            }
            Button("Open new terminal here") {
                // `open -a Terminal <folder>` opens a fresh Terminal window at that folder.
                DispatchQueue.global(qos: .userInitiated).async {
                    Shell.run("/usr/bin/open", ["-a", "Terminal", session.cwd])
                }
            }
            Divider()
            Button("Rename…") {
                if let name = TerminalFocus.askForName(current: session.displayName) {
                    SessionRegistry.setName(name, for: session)
                }
            }
            Button("Auto-name") { AutoNamer.rename(session) }
            Divider()
            Button("Clear context (/clear)") { model.clearContext(session) }
                .disabled(session.state == .busy)
            Button("Compact context (/compact)") { model.compactContext(session) }
                .disabled(session.state == .busy)
            Divider()
            if settings.prefs.skillLibrary {
                Menu("Add skill") {
                    ForEach(SkillLibrary.names(), id: \.self) { name in
                        let installed = SkillLibrary.isInstalled(name, in: session.cwd)
                        Button(installed ? "\(name) (added)" : name) { SkillLibrary.install(name, into: session.cwd) }
                            .disabled(installed)
                    }
                    Divider()
                    Button("Open skill library…") { SkillLibrary.reveal() }
                }
            }
            Button("Reveal folder in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
            }
            Button("Copy folder path") { copy(session.cwd) }
            Button("Copy session ID") { copy(session.sessionId) }
            Divider()
            if !(model.subagents[session.sessionId] ?? []).isEmpty {
                Button(expandedIds.contains(session.sessionId) ? "Hide subagents" : "Show subagents") {
                    toggleExpanded(session.sessionId)
                }
            }
            Button("Hide from list") { model.dismissed.insert(session.sessionId) }
        }
    }

    private func rowAction(
        _ symbol: String, tint: Color, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func needsCompact(_ session: AgentSession) -> Bool {
        guard session.state == .idle, let percent = contextPercent(session) else { return false }
        return Double(percent) >= settings.prefs.contextWarnPct * 100
    }

    private func toggleExpanded(_ sessionId: String) {
        if expandedIds.contains(sessionId) {
            expandedIds.remove(sessionId)
        } else {
            expandedIds.insert(sessionId)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func subagentRows(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.subagents[session.sessionId] ?? []) { subagent in
                HStack(spacing: 6) {
                    Circle()
                        .fill(subagent.running ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text(subagent.description)
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(subagent.running ? "running" : "done")
                        .font(.system(size: 9))
                        .foregroundStyle(subagent.running ? Color.green : secondaryText)
                }
            }
        }
        .padding(.leading, 27)
        .padding(.trailing, 8)
        .padding(.bottom, 2)
    }

    private var visible: [AgentSession] {
        model.sessions.filter { !model.dismissed.contains($0.sessionId) }
    }

    private var ordered: [AgentSession] {
        switch settings.prefs.needsYou ? .attention : settings.prefs.order {
        case .attention:
            // Waiting, then busy, then idle, then dead; within a group the one
            // that entered that state most recently comes first.
            return visible.sorted {
                let (a, b) = (rank($0), rank($1))
                return a != b ? a < b : stateSince($0) > stateSince($1)
            }
        case .newest:
            return visible.sorted { $0.startedAt > $1.startedAt }
        case .oldest:
            return visible.sorted { $0.startedAt < $1.startedAt }
        case .name:
            return visible.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    private func rank(_ session: AgentSession) -> Int {
        isDead(session) ? 3 : session.state.rank
    }

    /// When the session entered its current state, as far as the HUD has seen.
    private func stateSince(_ session: AgentSession) -> TimeInterval {
        switch session.state {
        case .busy: return model.busySince[session.sessionId]?.timeIntervalSince1970 ?? session.startedAt
        case .idle: return model.idleSince[session.sessionId]?.timeIntervalSince1970 ?? session.startedAt
        case .waiting: return session.startedAt
        }
    }

    /// Waiting on input, or just came back with a result to look at.
    private func needsYou(_ session: AgentSession) -> Bool {
        session.state == .waiting || justFinished(session)
    }

    /// Went idle from working within the last minute.
    private func justFinished(_ session: AgentSession) -> Bool {
        guard session.state == .idle, let at = model.finishedAt[session.sessionId] else { return false }
        return model.now.timeIntervalSince(at) < 60
    }

    private func isDead(_ session: AgentSession) -> Bool {
        guard session.state == .idle,
              let since = model.idleSince[session.sessionId] else { return false }
        return model.now.timeIntervalSince(since) >= settings.prefs.deadAfterHours * 3600
    }

    // MARK: Row text

    /// The session's permission mode; nil for the default mode.
    private func modeLabel(_ session: AgentSession) -> String? {
        switch model.permissionModes[session.sessionId] {
        case "plan": return "plan"
        case "auto": return "auto"
        case "acceptEdits": return "accept"
        case "bypassPermissions": return "bypass"
        case "dontAsk": return "no ask"
        default: return nil
        }
    }

    private func subtitle(_ session: AgentSession) -> String {
        var text = statusText(session)
        if settings.prefs.showModel, let name = model.modelNames[session.sessionId] {
            text += " · \(name.hasPrefix("claude-") ? String(name.dropFirst(7)) : name)"
        }
        if settings.prefs.showMode, let mode = modeLabel(session) {
            text += " · \(mode)"
        }
        if settings.prefs.showEffort, let effort = model.efforts[session.sessionId] {
            text += " · \(effort)"
        }
        return text
    }

    private func statusText(_ session: AgentSession) -> String {
        if naming.inFlight.contains(session.sessionId) { return "naming…" }
        switch session.state {
        case .waiting:
            return session.waitingFor ?? "waiting"
        case .idle:
            guard let since = model.idleSince[session.sessionId] else { return "idle" }
            let prefix = isDead(session) ? "dead, idle" : "idle"
            return "\(prefix) \(duration(since: since))"
        case .busy:
            let doing = model.activities[session.sessionId] ?? "working"
            guard let since = model.busySince[session.sessionId] else { return doing }
            return "\(doing) \(duration(since: since))"
        }
    }

    private func duration(since: Date) -> String {
        let seconds = max(0, Int(model.now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    private func contextPercent(_ session: AgentSession) -> Int? {
        guard let tokens = model.contextTokens[session.sessionId] else { return nil }
        return Int(Double(tokens) / Double(model.windowTokens(for: session.sessionId)) * 100)
    }

    // MARK: Colours

    private var primaryText: Color {
        settings.prefs.text.color.opacity(settings.prefs.textOpacity)
    }

    private var secondaryText: Color {
        settings.prefs.text.color.opacity(settings.prefs.textOpacity * 0.65)
    }

    private func statusColor(_ state: SessionStatus) -> Color {
        switch state {
        case .busy: return .green
        case .waiting: return .orange
        case .idle: return Color.secondary.opacity(0.5)
        }
    }

    /// Informational, not an alarm: past the threshold the figure steps up to
    /// primary text weight, never to a warning colour.
    private func contextColor(_ percent: Int) -> Color {
        Double(percent) >= settings.prefs.contextWarnPct * 100 ? primaryText : secondaryText
    }

    /// Informational: a limit Anthropic flags as warning or exceeded steps up
    /// to primary text weight, never to a warning colour.
    private func usageColor(_ limit: UsageLimit) -> Color {
        limit.severity == "normal" ? secondaryText : primaryText
    }
}
