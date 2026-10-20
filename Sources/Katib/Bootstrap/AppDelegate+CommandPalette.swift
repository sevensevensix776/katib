import AppKit
import KatibCore
import KatibClipboard
import KatibLauncher
import KatibScreenshot

/// Command palette command registration + hotkey install. Extracted
/// from AppDelegate's 1000+ LOC monolith to keep the coordinator file
/// focused on lifecycle + wiring. Swift extensions compile identically
/// to inline methods; only the file layout differs.
extension AppDelegate {
    func setupCommandPalette() {
        CommandRegistry.shared.register([
            KatibCommand(
                id: "katib.dictation.paste_last",
                title: "Paste last dictation again",
                subtitle: "Re-paste the most recent transcription",
                keywords: ["repeat", "again", "last", "transcription"],
                symbol: "doc.on.clipboard",
                section: .dictation
            ) { [weak self] in self?.rePasteLast() },

            KatibCommand(
                id: "katib.dictation.undo_last",
                title: "Undo last paste",
                subtitle: "Sends ⌘Z to the frontmost app",
                keywords: ["rollback", "revert"],
                symbol: "arrow.uturn.backward",
                section: .dictation
            ) { [weak self] in self?.outputManager.undoLastPaste() },

            KatibCommand(
                id: "katib.clipboard.show",
                title: "Show clipboard history",
                subtitle: "Floating picker with search",
                keywords: ["clip", "copy", "history", "paste"],
                symbol: "doc.on.clipboard",
                shortcutHint: "⌥⌘V",
                section: .clipboard
            ) { [weak self] in
                guard let self else { return }
                ClipboardPanelController.shared.toggle(clipboard: self.clipboard)
            },

            KatibCommand(
                id: "katib.clipboard.clear",
                title: "Clear clipboard history",
                subtitle: "Wipes everything except pinned",
                keywords: ["erase", "empty", "wipe"],
                symbol: "trash",
                section: .clipboard
            ) { [weak self] in
                // Confirm before destroying. The command palette can fire
                // its actions repeatedly under certain re-render paths;
                // an alert breaks any unintended loop and gives the user
                // an off-ramp.
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = "Clear clipboard history?"
                alert.informativeText = "Removes \(self.clipboard.items.count) item(s). Pinned items are kept. This can't be undone."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Clear")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    self.clipboard.clear()
                }
            },

            KatibCommand(
                id: "katib.screenshot.capture",
                title: "Capture screen region",
                subtitle: "Drag to select, then annotate",
                keywords: ["screenshot", "snip", "grab", "shot"],
                symbol: "camera.viewfinder",
                section: .screenshot
            ) { [weak self] in self?.screenshotManager.startCapture() },

            KatibCommand(
                id: "katib.settings.open",
                title: "Settings…",
                keywords: ["preferences", "prefs", "config"],
                symbol: "gearshape",
                shortcutHint: "⌘,",
                section: .settings
            ) { [weak self] in self?.openSettingsWindow() },

            KatibCommand(
                id: "katib.corrections.open",
                title: "Edit corrections",
                subtitle: "Casing, rewrites, phrases",
                keywords: ["dictionary", "rules", "fixes"],
                symbol: "character.book.closed",
                section: .settings
            ) { [weak self] in self?.openCorrectionsWindow() }
        ])
        CommandRegistry.shared.register(Self.systemSettingsCommands())
        CommandRegistry.shared.register([
            KatibCommand(
                id: "katib.quit",
                title: "Quit Katib",
                keywords: ["exit", "close"],
                symbol: "power",
                shortcutHint: "⌘Q",
                section: .general
            ) { NSApplication.shared.terminate(nil) }
        ])

        // Try ⌘Space first (Spotlight slot — many users disable Spotlight
        // or remap to Alfred-style behavior, and this is what muscle
        // memory wants for a launcher). Fall back to ⇧⌘K if some other
        // Carbon-registered app (Spotlight itself, Alfred, Raycast)
        // already owns ⌘Space. RegisterEventHotKey reports the conflict
        // synchronously, so we know on launch which one we got.
        //   kVK_Space = 49,  Cmd       = 0x100
        //   kVK_ANSI_K = 40, Shift+Cmd = 0x200 + 0x100 = 0x300
        CommandPaletteController.shared.installHotkey(preferences: [
            .init(keyCode: 49, modifiers: 0x100, label: "⌘Space"),
            .init(keyCode: 40, modifiers: 0x300, label: "⇧⌘K")
        ])

        // App launcher: enumerate installed .app bundles and register one
        // command per app. `start()` runs an initial sync scan and fires
        // onChange with the result, so the palette is populated before
        // the first ⇧⌘K. Subsequent fs events trigger debounced rescans
        // — new installs / uninstalls land in the palette without a
        // Katib relaunch.
        let launcher = AppLauncherIndex.shared
        launcher.onChange = { [weak self] entries in
            self?.applyLauncherEntries(entries)
        }
        launcher.start()
    }

    /// One palette command per System Settings pane Katib depends on.
    /// Every link goes through `SettingsPane` (verified on macOS 27).
    static func systemSettingsCommands() -> [KatibCommand] {
        [
            KatibCommand(
                id: "katib.permission.accessibility",
                title: "Open Accessibility Settings",
                subtitle: "Required for paste + global hotkeys. macOS 27 calls it Device Control and Data Access",
                keywords: ["access", "accessibility", "ax", "permission", "paste", "hotkey", "tcc"],
                symbol: "hand.raised",
                section: .settings
            ) { SettingsPane.accessibility.open() },

            KatibCommand(
                id: "katib.permission.microphone",
                title: "Open Microphone Settings",
                subtitle: "Required for dictation audio",
                keywords: ["mic", "microphone", "audio", "permission"],
                symbol: "mic",
                section: .settings
            ) { SettingsPane.microphone.open() },

            KatibCommand(
                id: "katib.permission.speech",
                title: "Open Speech Recognition Settings",
                subtitle: "Required to turn audio into text",
                keywords: ["speech", "recognition", "dictation", "transcribe", "permission"],
                symbol: "waveform",
                section: .settings
            ) { SettingsPane.speechRecognition.open() },

            KatibCommand(
                id: "katib.permission.screen",
                title: "Open Screen Recording Settings",
                subtitle: "Required for ⇧⌘3 / ⇧⌘4 screenshots",
                keywords: ["screen", "screenshot", "recording", "capture", "permission"],
                symbol: "rectangle.dashed",
                section: .settings
            ) { SettingsPane.screenRecording.open() },

            KatibCommand(
                id: "katib.permission.inputMonitoring",
                title: "Open Input Monitoring Settings",
                subtitle: "Snippet expansion and drag-to-snap watch keys and the mouse",
                keywords: ["input", "monitoring", "keyboard", "listen", "permission", "tcc"],
                symbol: "keyboard",
                section: .settings
            ) { SettingsPane.inputMonitoring.open() },

            KatibCommand(
                id: "katib.settings.siri",
                title: "Open Siri & Apple Intelligence Settings",
                subtitle: "AI polish needs Apple Intelligence on",
                keywords: ["siri", "apple intelligence", "ai", "polish", "foundation models"],
                symbol: "sparkles",
                section: .settings
            ) { SettingsPane.siri.open() },

            KatibCommand(
                id: "katib.settings.keyboard",
                title: "Open Keyboard Settings",
                subtitle: "System dictation key and shortcuts (free ⌘Space for the palette)",
                keywords: ["keyboard", "dictation", "shortcut", "spotlight", "fn", "globe"],
                symbol: "keyboard.badge.ellipsis",
                section: .settings
            ) { SettingsPane.keyboard.open() },

            KatibCommand(
                id: "katib.settings.loginItems",
                title: "Open Login Items Settings",
                subtitle: "Start Katib at login",
                keywords: ["login", "startup", "launch", "boot"],
                symbol: "power",
                section: .settings
            ) { SettingsPane.loginItems.open() },

            KatibCommand(
                id: "katib.settings.notifications",
                title: "Open Notifications Settings",
                keywords: ["notifications", "alerts", "banner"],
                symbol: "bell",
                section: .settings
            ) { SettingsPane.notifications.open() }
        ]
    }

    private func applyLauncherEntries(_ entries: [AppLauncherIndex.Entry]) {
        let registry = CommandRegistry.shared

        // Drop stale app commands so renames/uninstalls don't leave ghosts.
        // Only touches the .app section — other sections are owned by their
        // feature modules and registered once at launch.
        for cmd in registry.commands where cmd.section == .app {
            registry.unregister(id: cmd.id)
        }

        let commands = entries.map { entry -> KatibCommand in
            let url = entry.url
            return KatibCommand(
                id: "katib.app.\(entry.id)",
                title: entry.name,
                subtitle: "Open application",
                keywords: ["launch", "open", "app"],
                symbol: "app.fill",
                iconFileURL: url,
                section: .app
            ) {
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
            }
        }
        registry.register(commands)
        Logger.shared.log("AppLauncher: registered \(commands.count) apps in command palette")
    }

}
