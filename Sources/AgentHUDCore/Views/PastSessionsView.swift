import AppKit
import SwiftUI

struct PastSessionsView: View {
    @ObservedObject var store: PastSessionStore
    @ObservedObject private var naming = AutoNameStatus.shared
    let onResume: (PastSession) -> Void
    let onAutoName: (PastSession) -> Void
    @State private var hoveredId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            if store.sessions.isEmpty {
                Spacer()
                Text(store.loading ? "Looking for sessions…" : "No past sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.sessions) { session in
                            row(session)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 400, height: 480)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.sessions.isEmpty
                 ? "Past sessions"
                 : "\(store.sessions.count) most recent, click to resume")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if !naming.inFlight.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func row(_ session: PastSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(session.folder) · \(Self.age(of: session.lastActive))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if naming.inFlight.contains(session.id) {
                ProgressView()
                    .controlSize(.small)
            } else if hoveredId == session.id {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredId == session.id ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onResume(session) }
        .onHover { inside in
            hoveredId = inside ? session.id : (hoveredId == session.id ? nil : hoveredId)
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .contextMenu {
            Button("Resume in Terminal") { onResume(session) }
            Button("Fork") { TerminalFocus.resume(session, fork: true) }
            Button("Auto-name") { onAutoName(session) }
            Divider()
            Button("Copy session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
            Button("Reveal transcript in Finder") {
                NSWorkspace.shared.selectFile(session.transcript.path, inFileViewerRootedAtPath: "")
            }
        }
    }

    private static func age(of date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        case ..<604_800: return "\(seconds / 86_400)d ago"
        default: return "\(seconds / 604_800)w ago"
        }
    }
}
