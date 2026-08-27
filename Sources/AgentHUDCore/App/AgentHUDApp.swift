// Claude Agent HUD: a small always-on-top panel showing the state of local Claude Code
// sessions. Data sources, all local unless noted:
//   - `claude agents --json` for the session list and status (polled every 4s)
//   - each session's transcript tail (~/.claude/projects/...) for the last typed
//     prompt, context token count, and model, when those toggles are on
//   - Anthropic's usage endpoint, via the Claude Code OAuth token in the Keychain,
//     only while "Show usage left" is on (polled every 60s)
// Build and relaunch with ./build.sh.

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UserNotifications

import AppKit

// MARK: - Entry point

public enum AgentHUDApp {
    /// Held here rather than in a local so the delegate outlives `run()`;
    /// NSApplication holds its delegate weakly.
    private static let delegate = AppDelegate()

    /// Starts the app. Does not return.
    public static func run() {
        // Writing to a child process that has already exited raises SIGPIPE, which
        // would kill the app; treat it as an ordinary write error instead.
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
