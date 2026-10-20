import Foundation
import AppKit
import AVFoundation
import Combine
import Speech
import SwiftUI
import Sentry
import KatibCore
import KatibDictation
import KatibClipboard
import KatibScreenshot
import KatibWindow

/// Main app coordinator — menu bar popover, hotkey callbacks, recording flow.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let transcriber = StreamingTranscriber()
    let hotkeyManager = HotkeyManager.shared
    let outputManager = OutputManager.shared
    let correctionEngine = TextCorrectionEngine.shared
    let history = TranscriptionHistory.shared
    let settings = AppSettings.shared
    let updateChecker = UpdateChecker.shared
    let popoverState = PopoverState.shared
    let clipboard = ClipboardManager.shared
    let screenshotManager = ScreenshotManager.shared

    // `internal` so Bootstrap/AppDelegate+MenuBar.swift can manage these.
    var statusItem: NSStatusItem?
    var tapWatchdogTimer: Timer?
    var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var correctionsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    /// While non-nil, the post-release dictation pipeline routes the transcript
    /// here instead of pasting + recording history. Set by the Dictation Test
    /// step in WelcomeView so the user can verify the full pipeline without
    /// spraying text into whatever app happens to be frontmost.
    fileprivate var dictationTestCallback: ((String) -> Void)?

    private var lastTranscription: String? { popoverState.lastTranscription }
    private var lastRawText: String?
    private var activeAppWhenRecording: String?
    private var isProcessing = false
    private var startTask: Task<Void, Never>?
    private var recordingStartTime: Date?

    // `internal` so Bootstrap/AppDelegate+*.swift extensions can store sinks.
    var cancellables = Set<AnyCancellable>()
    private var recordingPulseTimer: Timer?
    private var recordingPulsePhase = false

    // Single-instance lock (see acquireSingleInstanceLock)
    nonisolated(unsafe) private static var lockFileHandle: FileHandle?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.acquireSingleInstanceLock() else {
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                let alert = NSAlert()
                alert.messageText = "Katib is already running"
                alert.informativeText = "Click the pencil icon in the menu bar."
                alert.runModal()
                NSApp.terminate(nil)
            }
            return
        }

        Self.startSentry()
        TranscriptionHistory.purgeLegacyHistoryIfNeeded()

        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)

            // Pre-permission setup — these are safe to run before any
            // permission is granted because they don't install event
            // taps, don't construct an audio engine, and don't register
            // global hotkeys. They wire callbacks and load user data.
            setupMenuBar()
            setupHotkeyCallbacks()

            if !settings.hasSeenWelcome {
                openWelcomeWindow()
            } else {
                autoOpenPopoverIfPermissionsMissing()
            }

            if settings.checkForUpdates {
                updateChecker.check()
            }
            if settings.syncPluginDictionaries {
                PluginDictionaries.shared.sync()
            }
            clipboard.capacity = settings.clipboardCapacity
            clipboard.evictExpiredItems()
            settings.$clipboardCapacity
                .dropFirst()
                .sink { [weak self] newCap in self?.clipboard.capacity = newCap }
                .store(in: &cancellables)

            // Bridge: every finalized screenshot also lands in clipboard
            // history. Closure wiring only — doesn't fire until the
            // screenshot manager actually captures something, which
            // can't happen until the screenshot hotkey is installed in
            // bootstrap. Safe to set early.
            screenshotManager.onCaptured = { [weak self] pngData, w, h in
                self?.clipboard.recordCapturedImage(pngData: pngData, width: w, height: h)
            }

            // Diagnostic keystroke tap — gated on debugTranscripts so
            // teammates don't get log spam. Syncs with the setting.
            KeystrokeDebugTap.shared.isEnabled = settings.debugTranscripts
            settings.$debugTranscripts
                .dropFirst()
                .sink { enabled in
                    Task { @MainActor in KeystrokeDebugTap.shared.isEnabled = enabled }
                }
                .store(in: &cancellables)

            // Dangerous setup goes through the coordinator. It only
            // runs `runFullBootstrap` once all three permissions
            // (mic / speech / accessibility) are granted, and
            // `runTeardown` if any are revoked after that. Eliminates
            // the half-init class of bug where the transcriber was set
            // up under a no-AX world and the hotkey tap was bootstrapped
            // 22s later under an AX-granted-live world.
            // willSleep hook — the coordinator subscribes to
            // NSWorkspace.willSleepNotification and invokes this so the
            // audio engine doesn't slot into an undefined post-wake
            // state if the user happens to be dictating when sleep
            // starts. Hold-to-talk makes this hard to trigger in
            // practice but the cost of a defensive abort is trivial.
            BootstrapCoordinator.shared.willSleep = { [weak self] in
                guard let self, self.transcriber.isRecording else { return }
                Logger.shared.log("BOOT: aborting active recording before sleep")
                self.abortRecording()
            }

            BootstrapCoordinator.shared.start(
                bootstrap: { [weak self] traceID in
                    await self?.runFullBootstrap(traceID: traceID)
                },
                teardown: { [weak self] traceID in
                    self?.runTeardown(traceID: traceID)
                }
            )
        }
    }

    /// Permission-gated startup. Only runs when mic, speech, and
    /// accessibility are all granted. The trace ID gets stamped into
    /// every log line so a single bootstrap cycle is grep-able.
    @MainActor
    private func runFullBootstrap(traceID: String) async {
        Logger.shared.log("BOOT[\(traceID)]: starting transcriber.setup")
        await transcriber.setup()
        Logger.shared.log("BOOT[\(traceID)]: transcriber ready — \(transcriber.statusMessage)")

        // Build the live-indicator NSWindow + SwiftUI hierarchy now so
        // the first dictation isn't delayed by a 1–2s first-show build.
        LiveIndicatorWindowController.shared.prewarm()
        Logger.shared.log("BOOT[\(traceID)]: live indicator prewarmed")

        // HotkeyManager polls AX internally too — but the coordinator
        // already gated us on AX being granted, so startListening should
        // succeed immediately. Idempotent if already running.
        hotkeyManager.checkAccessibilityPermission()
        hotkeyManager.startListening()
        Logger.shared.log("BOOT[\(traceID)]: hotkey listener started")

        setupClipboardHotkey()
        setupCommandPalette()
        // Self-test: `open Katib.app --args -paletteQuery "text"` opens the
        // palette with the query typed in, for screenshots without synthetic
        // keystrokes. Read from the argument domain only, never saved.
        if let q = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["paletteQuery"] as? String {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.activate(ignoringOtherApps: true)
                CommandPaletteController.shared.show(initialQuery: q)
            }
        }
        // Self-test: `open Katib.app --args -showPopover YES` opens the menu bar popover.
        if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["showPopover"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.togglePopover()
            }
        }
        setupWindowManager()
        setupVoiceCommands()
        setupScreenshotHotkey()
        Logger.shared.log("BOOT[\(traceID)]: all hotkey surfaces installed")
    }

    /// Reverse of `runFullBootstrap`. Stops every event-tap consumer +
    /// the audio pipeline so a permission revocation doesn't leave us
    /// in a half-broken state. User data (clipboard, settings,
    /// corrections) stays loaded — those don't depend on permissions
    /// and reloading them on every grant cycle would be wasteful.
    @MainActor
    private func runTeardown(traceID: String) {
        Logger.shared.log("BOOT[\(traceID)]: teardown begin")

        // Abort any in-flight recording. abortRecording is safe to call
        // when nothing is running.
        abortRecording()

        // Stop the modifier observer + key listener.
        hotkeyManager.stopListening()

        // Recycle the tap. Without this, AX revoked at runtime (user
        // toggles Privacy in System Settings) leaves the same zombie
        // tap state as the sleep/wake bug — the kernel routes events
        // through a tap whose permission check now fails, and the
        // keyboard goes dark. Destroy + (try to) recreate; create
        // fails cleanly when AX is gone and we've removed all our
        // consumers anyway.
        HotkeyTapRouter.shared.recycleTap()

        Logger.shared.log("BOOT[\(traceID)]: teardown done")
    }

    // setupVoiceCommands() lives in Bootstrap/AppDelegate+VoiceCommands.swift

    // setupWindowManager() + installWindowBinding() live in Bootstrap/AppDelegate+Windows.swift

    // setupCommandPalette() lives in Bootstrap/AppDelegate+CommandPalette.swift

    /// Install both screenshot hotkeys (quick capture + annotate) and wire
    /// them to the corresponding ScreenshotManager entry points. Reinstalls
    /// when the user rebinds either combo in Settings.
    // setupScreenshotHotkey() lives in Bootstrap/AppDelegate+Screenshot.swift

    // setupClipboardHotkey() lives in Bootstrap/AppDelegate+Clipboard.swift

    /// If any required permission is missing on launch, show the popover so
    /// the user sees the inline Grant buttons without having to click the menu icon.
    private func autoOpenPopoverIfPermissionsMissing() {
        popoverState.refreshPermissions()
        let accessibilityGranted = hotkeyManager.hasAccessibilityPermission

        guard !(popoverState.microphoneGranted && popoverState.speechGranted && accessibilityGranted) else { return }

        Logger.shared.log("Missing permissions on launch — opening popover (mic=\(popoverState.microphoneGranted) speech=\(popoverState.speechGranted) a11y=\(accessibilityGranted))")

        // Brief delay so the status item is fully laid out before we anchor the popover.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let button = self.statusItem?.button, let popover = self.popover, !popover.isShown else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Menu bar imagery

    /// Arabic ك (kaf — the first letter of كاتب / "Scribe") rendered as a
    /// template image so macOS tints it for light/dark mode automatically.
    /// Falls back to a SF symbol if text rendering somehow fails.
    static let idleMenuBarImage: NSImage = makeKafImage(filled: false)
    static let recordingMenuBarImage: NSImage = makeKafImage(filled: true)

    private static func makeKafImage(filled: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let glyph = "ك"
            let font = NSFont.systemFont(ofSize: 16, weight: filled ? .bold : .medium)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black, // black = template tint
                .paragraphStyle: para
            ]
            let str = NSAttributedString(string: glyph, attributes: attrs)
            let textSize = str.size()
            let point = NSPoint(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2
            )
            str.draw(at: point)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = filled ? "Katib recording" : "Katib"
        return image
    }

    // MARK: - Sentry

    nonisolated private static func startSentry() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        // Only an edition that names a DSN reports crashes.
        guard let dsn = Edition.sentryDSN else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sevensevensix.katib"
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "\(bundleID)@\(version)"
            options.environment = "production"
            // Dictation tool — never ship user content to a third party.
            options.sendDefaultPii = false
            options.enableAutoSessionTracking = true
            options.enableCrashHandler = true
            // Defense-in-depth: strip any breadcrumb that accidentally embeds text
            // that looks like transcribed content (app name, last N, corrected, etc.).
            options.beforeBreadcrumb = { crumb in
                guard let msg = crumb.message?.lowercased() else { return crumb }
                let blocked = ["corrected:", "last:", "re-paste:", "recording, app:"]
                if blocked.contains(where: { msg.contains($0) }) { return nil }
                return crumb
            }
            // Crash events can still capture stack-resident strings via
            // event.message. Exception values we leave alone because Swift
            // exception messages are type-names / symbol-names, not transcription
            // content — redacting would make crashes unreadable.
            options.beforeSend = { event in
                if let msg = event.message?.message, msg.count > 100 {
                    // Anything suspiciously long is redacted — real log messages
                    // we emit are short, transcription dumps would be long.
                    event.message?.message = "<redacted \(msg.count) chars>"
                }
                return event
            }
        }
    }

    // MARK: - Single-instance lock

    /// Code-mode gate. Only fires when the frontmost bundle-ID matches
    /// the user's configured regex (case-insensitive substring). Blank
    /// pattern disables code mode everywhere.
    nonisolated static func shouldApplyCodeMode(bundleID: String?, pattern: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty, !pattern.isEmpty else { return false }
        return bundleID.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated private static func acquireSingleInstanceLock() -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("Katib", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockPath = folder.appendingPathComponent(".instance.lock").path

        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: lockPath) else { return false }
        if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            lockFileHandle = handle
            handle.truncateFile(atOffset: 0)
            handle.write("\(ProcessInfo.processInfo.processIdentifier)".data(using: .utf8)!)
            return true
        }
        try? handle.close()
        return false
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        if let handle = Self.lockFileHandle {
            flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
            Self.lockFileHandle = nil
        }
    }

    // MARK: - Menu Bar
    // setupMenuBar() + context menu + watchdog live in Bootstrap/AppDelegate+MenuBar.swift

    // MARK: - Child Windows

    // `internal` so Bootstrap/AppDelegate+CommandPalette.swift can call it.
    func openSettingsWindow() {
        popover?.performClose(nil)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(settings: settings, hotkeyManager: hotkeyManager)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Katib Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openWelcomeWindow() {
        if let window = welcomeWindow {
            bringToFront(window)
            return
        }
        let view = WelcomeView(
            hotkeyName: settings.hotkeySide.displayName,
            installTestCallback: { [weak self] callback in
                self?.dictationTestCallback = callback
            },
            onDone: { [weak self] in
                self?.settings.hasSeenWelcome = true
                self?.dictationTestCallback = nil
                self?.welcomeWindow?.close()
                self?.welcomeWindow = nil
                self?.autoOpenPopoverIfPermissionsMissing()
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Katib"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        welcomeWindow = window
        bringToFront(window)
    }

    /// On a first launch the Gatekeeper "downloaded from the Internet" dialog
    /// holds activation, and macOS can refuse ours, so makeKeyAndOrderFront
    /// alone leaves the window behind other apps. orderFrontRegardless shows
    /// it anyway; the retry makes it key once activation is allowed.
    private func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard window.isVisible, !NSApp.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    // `internal` so Bootstrap/AppDelegate+CommandPalette.swift can call it.
    func openCorrectionsWindow() {
        popover?.performClose(nil)

        if let window = correctionsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = CorrectionsEditorView(engine: correctionEngine)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Katib Corrections"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        correctionsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // `internal` so Bootstrap/AppDelegate+CommandPalette.swift can call it.
    func rePasteLast() {
        guard let text = lastTranscription else { return }
        Logger.shared.log("Re-paste from menu (\(Logger.summarize(text)))")
        outputManager.pasteText(text)
    }

    /// Entry points for App Intents — Spotlight/Shortcuts/Siri call into these.
    func performRePasteLastViaIntent() {
        rePasteLast()
    }

    func performOpenCorrectionsViaIntent() {
        openCorrectionsWindow()
    }

    // MARK: - Hotkey Callbacks
    // setupHotkeyCallbacks() lives in Bootstrap/AppDelegate+Dictation.swift

    // `internal` so Bootstrap/AppDelegate+Dictation.swift can wire callbacks.
    func abortRecording() {
        guard startTask != nil else { return }
        Logger.shared.log("Aborting — Esc while holding hotkey")
        startTask?.cancel()
        Task { @MainActor in
            _ = await transcriber.stopRecording()
        }
        stopRecordingPulse()
        if let button = statusItem?.button {
            button.image = Self.idleMenuBarImage
        }
        LiveIndicatorWindowController.shared.updateState(.error("Cancelled"))
        if settings.playFeedbackSounds { NSSound(named: "Basso")?.play() }
    }

    // MARK: - Recording pulse

    /// Alternate menu bar icon between idle + recording every 500ms while
    /// holding the hotkey. Low-key visual confirmation that dictation is live,
    /// without the color flash that might distract.
    private func startRecordingPulse() {
        recordingPulsePhase = true
        recordingPulseTimer?.invalidate()
        recordingPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem?.button else { return }
                self.recordingPulsePhase.toggle()
                button.image = self.recordingPulsePhase
                    ? Self.recordingMenuBarImage
                    : Self.idleMenuBarImage
            }
        }
    }

    private func stopRecordingPulse() {
        recordingPulseTimer?.invalidate()
        recordingPulseTimer = nil
        recordingPulsePhase = false
    }

    // MARK: - Double Tap

    func doubleTapRePaste() {
        guard let text = lastTranscription else {
            Logger.shared.log("Double-tap: no previous transcription")
            return
        }
        Logger.shared.log("Double-tap → re-paste (\(Logger.summarize(text)))")
        outputManager.pasteText(text)

        if settings.showLiveIndicator {
            LiveIndicatorWindowController.shared.show(transcriber: transcriber)
            LiveIndicatorWindowController.shared.updateState(.success("Re-pasted"))
        }
    }

    // MARK: - Recording Flow

    func startRecording() {
        guard transcriber.isReady, !isProcessing else {
            Logger.shared.log("Ignored: ready=\(transcriber.isReady), processing=\(isProcessing)")
            return
        }

        let traceID = TraceID.new()
        activeAppWhenRecording = NSWorkspace.shared.frontmostApplication?.localizedName
        recordingStartTime = Date()
        Logger.shared.log("DICT[\(traceID)]: hotkey-down (active=\(activeAppWhenRecording ?? "<unknown>"))")

        // Kick off audio-engine setup IMMEDIATELY — before any UI work.
        // Everything else is cosmetic and can ride the next runloop tick
        // without blocking the Task that actually needs to bring the mic
        // up. Swift Task scheduling puts this at the head of the main
        // actor's queue; the async UI block runs after.
        transcriber.contextualTerms = correctionEngine.recognitionTerms
        startTask = Task {
            do {
                try await transcriber.startRecording(traceID: traceID)
            } catch {
                Logger.shared.log("DICT[\(traceID)]: ERROR starting: \(error)")
                LiveIndicatorWindowController.shared.hide()
            }
        }

        DispatchQueue.main.async { [weak self] in self?.showRecordingUI() }
    }

    private func showRecordingUI() {
        if let button = statusItem?.button {
            button.image = Self.recordingMenuBarImage
        }
        startRecordingPulse()
        if settings.showLiveIndicator {
            LiveIndicatorWindowController.shared.show(transcriber: transcriber)
        }
        if settings.playFeedbackSounds {
            NSSound(named: "Tink")?.play()
        }
    }

    func stopRecordingAndPaste() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        Logger.shared.log("Key UP → stopping")

        if let task = startTask {
            await task.value
            startTask = nil
        }

        stopRecordingPulse()
        if let button = statusItem?.button {
            button.image = Self.idleMenuBarImage
        }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        guard let rawText = await transcriber.stopRecording() else {
            Logger.shared.log("No transcription result")
            LiveIndicatorWindowController.shared.updateState(
                .error("Didn't catch that — check your mic and try again.")
            )
            if settings.playFeedbackSounds {
                NSSound(named: "Basso")?.play()
            }
            return
        }

        // Voice command intercept: if the raw transcription matches a
        // registered command pattern, execute it and skip the paste path
        // entirely. "New paragraph" substitutes a literal \n\n; "split left"
        // snaps the window; "cancel" drops the transcription silently.
        if let outcome = VoiceCommandMatcher.shared.match(on: rawText) {
            switch outcome {
            case .execute(let action):
                action()
                LiveIndicatorWindowController.shared.updateState(.success("Command"))
                if settings.playFeedbackSounds { NSSound(named: "Pop")?.play() }
                return
            case .insertText(let literal):
                outputManager.pasteText(literal, expectedApp: activeAppWhenRecording)
                LiveIndicatorWindowController.shared.updateState(.success("Inserted"))
                if settings.playFeedbackSounds { NSSound(named: "Pop")?.play() }
                return
            }
        }

        let pipelineStart = Date()

        let correctStart = Date()
        var correctedText = correctionEngine.correct(rawText)
        let correctMs = Int(Date().timeIntervalSince(correctStart) * 1000)
        Logger.shared.log("Corrected transcription (\(Logger.summarize(correctedText)))")
        if settings.debugTranscripts {
            Logger.shared.logContent("DEBUG corrected", correctedText)
        }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var codeMs = 0
        if Self.shouldApplyCodeMode(bundleID: bundleID, pattern: settings.codeModeAppPattern) {
            let before = correctedText
            let codeStart = Date()
            correctedText = CodePhoneticProcessor.process(correctedText)
            codeMs = Int(Date().timeIntervalSince(codeStart) * 1000)
            if correctedText != before {
                Logger.shared.log("Code mode applied (\(bundleID ?? "?"))")
                if settings.debugTranscripts {
                    Logger.shared.logContent("DEBUG code-mode", correctedText)
                }
            }
        }

        var polishMs = 0
        let polishApplied = settings.aiPolishEnabled && AICleanup.shared.isAvailable && dictationTestCallback == nil
        if polishApplied {
            let polishStart = Date()
            correctedText = await AICleanup.shared.polish(correctedText, bundleID: bundleID)
            polishMs = Int(Date().timeIntervalSince(polishStart) * 1000)
            if settings.debugTranscripts {
                Logger.shared.logContent("DEBUG polished", correctedText)
            }
        }

        if let testCallback = dictationTestCallback {
            let totalMs = Int(Date().timeIntervalSince(pipelineStart) * 1000)
            Logger.shared.log("DICT pipeline: correct=\(correctMs)ms code=\(codeMs)ms polish=0ms paste=0ms total=\(totalMs)ms testMode=true")
            testCallback(correctedText)
            // The dictation window must still finish: without this it stays
            // on "listening" after the welcome test.
            LiveIndicatorWindowController.shared.updateState(.success("Test heard"))
            if settings.playFeedbackSounds { NSSound(named: "Pop")?.play() }
            return
        }

        popoverState.pushRecent(correctedText)
        lastRawText = rawText

        history.save(
            raw: rawText,
            corrected: correctedText,
            duration: duration,
            app: activeAppWhenRecording ?? "unknown"
        )

        let pasteStart = Date()
        let result = outputManager.pasteText(correctedText, expectedApp: activeAppWhenRecording)
        let pasteMs = Int(Date().timeIntervalSince(pasteStart) * 1000)
        let totalMs = Int(Date().timeIntervalSince(pipelineStart) * 1000)
        Logger.shared.log("DICT pipeline: correct=\(correctMs)ms code=\(codeMs)ms polish=\(polishMs)ms paste=\(pasteMs)ms total=\(totalMs)ms aiPolish=\(polishApplied)")

        switch result {
        case .ok:
            let preview = correctedText.count > 60 ? String(correctedText.prefix(60)) + "..." : correctedText
            LiveIndicatorWindowController.shared.updateState(.success(preview))
            if settings.playFeedbackSounds { NSSound(named: "Pop")?.play() }
            if settings.saveDictationsToClipboard {
                clipboard.append(correctedText, sourceApp: "Katib dictation")
            }
        case .refusedSecureField:
            LiveIndicatorWindowController.shared.updateState(
                .error("Looks like a password field — skipped paste for safety. Copy it manually if you need to.")
            )
            if settings.playFeedbackSounds { NSSound(named: "Basso")?.play() }
        case .refusedFocusChanged(_, let to):
            LiveIndicatorWindowController.shared.updateState(
                .error("You switched to \(to ?? "another app") — skipped paste. Use the popover to paste again once you're back.")
            )
            if settings.playFeedbackSounds { NSSound(named: "Basso")?.play() }
        }
    }
}
