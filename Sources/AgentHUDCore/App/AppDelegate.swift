import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UserNotifications

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var popover: NSPopover?
    private var lastMode: DisplayMode?
    private var lastUsageInterval: Double?
    private var settingsWindow: NSWindow?
    private var pastSessionsWindow: NSWindow?
    private let pastSessions = PastSessionStore()
    private let model = AgentModel()
    private let usage = UsageService()
    private let settings = Settings()
    private var settingsObservation: AnyCancellable?
    private var hotKey: HotKey?
    private let contextMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = Notifier.shared
        AutoNamer.onNamed = { [weak model] sessionId in model?.resetPromptCount(for: sessionId) }
        applyPrefs(settings.prefs)
        settingsObservation = settings.$prefs.sink { [weak self] prefs in
            self?.applyPrefs(prefs)
        }
        makePanel()
        makeStatusItem()
        model.hudVisible = { [weak self] in
            guard let self else { return false }
            return panel.isVisible || popover?.isShown == true
        }
        model.start()
        usage.refresh()
        applyDisplay(settings.prefs)
        hotKey = HotKey(keyCode: kVK_ANSI_A, modifiers: cmdKey | optionKey) { [weak self] in
            self?.togglePanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return false
    }

    /// The Dock menu; macOS appends its own Quit.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        fill(menu, withQuit: false)
        return menu
    }

    /// One layout for the menu bar and Dock menus. Clear all sits alone at
    /// the top so it is not hit by accident; nil is a separator.
    private func fill(_ menu: NSMenu, withQuit: Bool) {
        var items: [(String, Selector)?] = [
            ("Clear all…", #selector(clearAll)),
            nil,
            ("Show panel", #selector(showPanel)),
            ("Hide panel", #selector(hidePanel)),
            ("Past sessions…", #selector(openPastSessions)),
            ("Auto-name all", #selector(autoNameAll)),
            nil,
            ("Settings…", #selector(openSettings)),
        ]
        if withQuit {
            items += [nil, ("Quit Claude Agent HUD", #selector(quit))]
        }
        for entry in items {
            guard let (title, action) = entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    // MARK: Prefs application

    private func applyPrefs(_ prefs: Prefs) {
        model.showPrompts = prefs.showLastPrompt
        model.showContext = prefs.showContext
        model.showModel = prefs.showModel
        model.warnFraction = prefs.contextWarnPct
        model.notifyContext = prefs.notifyHighContext
        model.notifyWaiting = prefs.notifyWaiting
        model.notifyFinished = prefs.notifyFinished
        model.driftRename = prefs.driftRename
        model.driftRenameAfter = Int(prefs.driftRenameAfter)
        let usageTurnedOn = !usage.enabled && prefs.showUsage
        usage.enabled = prefs.showUsage
        if usageTurnedOn { usage.refresh() }
        if prefs.usageRefreshMinutes != lastUsageInterval {
            lastUsageInterval = prefs.usageRefreshMinutes
            usage.schedule(everyMinutes: prefs.usageRefreshMinutes)
        }
        applyDisplay(prefs)
    }

    private func applyDisplay(_ prefs: Prefs) {
        guard panel != nil else { return }  // sink can fire before makePanel
        NSApp.setActivationPolicy(prefs.showInDock ? .regular : .accessory)
        guard prefs.displayMode != lastMode else { return }
        lastMode = prefs.displayMode
        switch prefs.displayMode {
        case .overlay:
            popover?.performClose(nil)
            panel.level = .statusBar
            panel.orderFrontRegardless()
        case .window:
            popover?.performClose(nil)
            panel.level = .normal
            panel.orderFrontRegardless()
        case .dropdown:
            panel.orderOut(nil)
        }
    }

    // MARK: UI construction

    private func makeHUD(onClose: @escaping () -> Void) -> NSHostingController<HUDView> {
        NSHostingController(
            rootView: HUDView(
                model: model,
                settings: settings,
                usage: usage,
                onClose: onClose,
                onSettings: { [weak self] in self?.openSettings() },
                onPastSessions: { [weak self] in self?.openPastSessions() }
            )
        )
    }

    private func makePanel() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = makeHUD(onClose: { [weak self] in
            self?.panel.orderOut(nil)
        })
        if let contentView = panel.contentViewController?.view {
            panel.setContentSize(contentView.fittingSize)
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(
                x: frame.maxX - panel.frame.width - 12,
                y: frame.maxY - 12
            ))
        }
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude Agent HUD")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        fill(contextMenu, withQuit: true)
    }

    private func showDropdown() {
        if popover == nil {
            let created = NSPopover()
            created.behavior = .transient
            created.contentViewController = makeHUD(onClose: { [weak self] in
                self?.popover?.performClose(nil)
            })
            popover = created
        }
        guard let popover, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: Actions

    /// Either click opens the menu. In dropdown mode a left click shows the
    /// dropdown instead, since that is what the mode is for.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if settings.prefs.displayMode == .dropdown, !rightClick {
            showDropdown()
            return
        }
        // A status item can't have both a click action and a menu; attach
        // the menu just long enough to pop it open.
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func togglePanel() {
        if settings.prefs.displayMode == .dropdown {
            showDropdown()
        } else if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func showPanel() {
        if settings.prefs.displayMode == .dropdown {
            showDropdown()
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func hidePanel() {
        popover?.performClose(nil)
        panel.orderOut(nil)
    }

    @objc private func autoNameAll() {
        AutoNamer.renameAll(model.sessions)
    }

    /// Clears every listed session that is sitting at its prompt. Working
    /// sessions are left alone: a /clear typed mid-task would only run once the
    /// task finished, wiping the context it had just built.
    @objc private func clearAll() {
        let sessions = model.sessions.filter {
            $0.state != .busy && !model.dismissed.contains($0.sessionId)
        }
        guard !sessions.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = sessions.count == 1
            ? "Clear context in 1 session?"
            : "Clear context in \(sessions.count) sessions?"
        alert.informativeText = "Types /clear into each waiting or idle session's terminal. Working sessions are skipped."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TerminalFocus.clearContext(pids: sessions.map(\.pid))
        sessions.forEach(model.noteCleared)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView(settings: settings))
            )
            window.title = "Claude Agent HUD Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openPastSessions() {
        if pastSessionsWindow == nil {
            let view = PastSessionsView(
                store: pastSessions,
                onResume: { [weak self] session in
                    TerminalFocus.resume(session)
                    self?.pastSessions.remove(session.id)
                },
                onAutoName: { [weak self] session in
                    AutoNamer.rename(past: session) { name in
                        if let name { self?.pastSessions.setName(name, for: session.id) }
                    }
                }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Past Sessions"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            pastSessionsWindow = window
        }
        pastSessions.reload(excluding: Set(model.sessions.map(\.sessionId)))
        NSApp.activate(ignoringOtherApps: true)
        pastSessionsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
