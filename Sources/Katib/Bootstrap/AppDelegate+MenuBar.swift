import AppKit
import SwiftUI
import KatibCore

/// Menu bar wiring — status item, icon, popover, context menu, and the
/// watchdog loop that dims the icon when the hotkey tap dies (usually
/// means Accessibility permission was revoked). Auto-recovers once the
/// tap comes back.
extension AppDelegate: NSPopoverDelegate {
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = Self.idleMenuBarImage
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Katib — hold \(settings.hotkeySide.displayName) to dictate"
        }

        NotificationCenter.default.addObserver(
            forName: .katibHotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem?.button?.toolTip = "Katib — hold \(self.settings.hotkeySide.displayName) to dictate"
            }
        }

        updateChecker.$available
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                self?.refreshMenuBarStatus(updateAvailable: available)
            }
            .store(in: &cancellables)

        // Watchdog: every 3s, surface whether the hotkey tap is dead (usually
        // = missing Accessibility). If dead → dim the icon + swap tooltip so
        // the user sees it's broken instead of silently pressing hotkeys that
        // do nothing. Auto-recovers once AX is granted: HotkeyTapRouter
        // listens for didBecomeActive and retries install, and this loop
        // flips the UI back.
        tapWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMenuBarStatus(updateAvailable: self?.updateChecker.available ?? false)
            }
        }

        popover = NSPopover()
        popover?.behavior = .transient
        popover?.animates = true
        popover?.delegate = self

        let view = MenuBarView(
            hotkeyManager: hotkeyManager,
            transcriber: transcriber,
            settings: settings,
            corrections: correctionEngine,
            updateChecker: updateChecker,
            popoverState: popoverState,
            clipboard: clipboard,
            history: history,
            openSettings: { [weak self] in self?.openSettingsWindow() },
            openCorrections: { [weak self] in self?.openCorrectionsWindow() },
            onRePasteLast: { [weak self] in self?.rePasteLast() },
            onUndoLast: { [weak self] in self?.outputManager.undoLastPaste() }
        )
        popover?.contentViewController = NSHostingController(rootView: view)
    }

    // The hosting controller stays alive while closed; without this the header
    // owl keeps redrawing at 15 fps for nobody.
    func popoverWillShow(_ notification: Notification) { popoverState.isVisible = true }
    func popoverDidClose(_ notification: Notification) { popoverState.isVisible = false }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu(from: sender)
        } else {
            togglePopover()
        }
    }

    /// Update the menu bar icon + tooltip to reflect both the hotkey-tap
    /// health AND the update-available state. Dead tap (usually missing
    /// Accessibility) takes precedence — it's the most actionable failure.
    func refreshMenuBarStatus(updateAvailable: Bool) {
        guard let button = statusItem?.button else { return }
        let tapDead = HotkeyTapRouter.shared.isTapDead
        button.appearsDisabled = tapDead
        if tapDead {
            button.toolTip = "Katib — Accessibility permission missing. Grant in System Settings → Privacy & Security → Accessibility."
        } else if updateAvailable {
            button.toolTip = "Katib — update available (click to download)"
        } else {
            button.toolTip = "Katib — hold \(settings.hotkeySide.displayName) to dictate"
        }
    }

    func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popoverState.refreshPermissions()
        hotkeyManager.checkAccessibilityPermission()

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Show Katib", action: #selector(togglePopoverFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        if settings.screenshotEnabled {
            let capture = NSMenuItem(title: "Capture Region…", action: #selector(captureFromMenu), keyEquivalent: "")
            capture.target = self
            menu.addItem(capture)
        }

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let correct = NSMenuItem(title: "Edit Corrections…", action: #selector(openCorrectionsFromMenu), keyEquivalent: "")
        correct.target = self
        menu.addItem(correct)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Katib", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func togglePopoverFromMenu() { togglePopover() }
    @objc func captureFromMenu() { screenshotManager.startCapture() }
    @objc func openSettingsFromMenu() { openSettingsWindow() }
    @objc func openCorrectionsFromMenu() { openCorrectionsWindow() }
}
