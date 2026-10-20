import SwiftUI
import AppKit
import AVFoundation
import Speech
import KatibCore
import KatibDictation
import KatibClipboard
import KatibScreenshot
import KatibSnippets
import KatibWindow

/// Sidebar-navigated Settings window. Each category maps to one pane so the
/// window stays a comfortable size regardless of feature growth.
@MainActor
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotkeyManager: HotkeyManager

    @State private var selected: Category = .general

    enum Category: String, CaseIterable, Identifiable {
        case general
        case shortcuts
        case dictation
        case clipboard
        case screenshot
        case window
        case permissions
        case advanced

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .dictation: return "Dictation"
            case .clipboard: return "Clipboard"
            case .screenshot: return "Screenshot"
            case .window: return "Window"
            case .permissions: return "Permissions"
            case .advanced: return "Advanced"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "command"
            case .dictation: return "waveform"
            case .clipboard: return "doc.on.clipboard"
            case .screenshot: return "camera.viewfinder"
            case .window: return "rectangle.split.2x1"
            case .permissions: return "lock.shield"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Category.allCases, selection: $selected) { category in
                Label(category.displayName, systemImage: category.symbol)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 640)
        .tint(AppColors.bronze)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selected {
        case .general: GeneralSettingsPane(settings: settings)
        case .shortcuts: ShortcutsSettingsPane(settings: settings)
        case .dictation: DictationSettingsPane(settings: settings)
        case .clipboard: ClipboardSettingsPane(settings: settings)
        case .screenshot: ScreenshotSettingsPane(settings: settings)
        case .window: WindowSettingsPane(settings: settings)
        case .permissions: PermissionsSettingsPane(hotkeyManager: hotkeyManager)
        case .advanced: AdvancedSettingsPane(settings: settings)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var plugins = PluginRegistry.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch Katib when you log in", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                Toggle("Check for updates at launch", isOn: $settings.checkForUpdates)
            }
            Section("Plugins") {
                if plugins.plugins.isEmpty {
                    Text("No plugins installed.").foregroundColor(.secondary)
                }
                ForEach(plugins.plugins) { plugin in
                    HStack {
                        Text(plugin.name)
                        Spacer()
                        Text(Self.summary(plugin)).font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle("Sync plugin dictionaries", isOn: $settings.syncPluginDictionaries)
                HStack {
                    Button("Open Plugins Folder") { NSWorkspace.shared.open(PluginRegistry.userFolder) }
                    Button("Reload") {
                        plugins.reload(force: true)
                        if settings.syncPluginDictionaries { PluginDictionaries.shared.sync(force: true) }
                    }
                }
                Text("""
                    A plugin is a folder with a plugin.json. It can add a search source to ⌘Space or a dictionary \
                    of names and terms. See the README for the format.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Feedback") {
                Toggle("Play sounds on start and stop", isOn: $settings.playFeedbackSounds)
                Toggle("Show the floating indicator while recording", isOn: $settings.showLiveIndicator)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

private extension GeneralSettingsPane {
    static func summary(_ plugin: Plugin) -> String {
        var parts: [String] = []
        if plugin.searchCommand != nil { parts.append("search") }
        if plugin.dictionaryFile != nil { parts.append("dictionary") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Dictation

private struct DictationSettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Press and hold", selection: $settings.hotkeySide) {
                    ForEach(AppSettings.HotkeySide.allCases) { side in
                        Text(side.displayName).tag(side)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("Solo press only — combos like ⌘⌥ are ignored so normal shortcuts keep working. Press Esc during a recording to cancel without pasting.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if AICleanup.shared.isAvailable {
                Section("AI polish") {
                    Toggle("Polish transcriptions with on-device AI", isOn: $settings.aiPolishEnabled)
                    Text("Fixes punctuation, removes restarts, cleans fillers. Runs on your Mac via Apple Foundation Models — nothing leaves the device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.aiPolishEnabled {
                    Section("AI cleanup prompt") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("System prompt")
                                .font(.subheadline)
                            TextEditor(text: $settings.aiCleanupPrompt)
                                .font(.system(.callout, design: .monospaced))
                                .frame(minHeight: 120)
                                .padding(6)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            HStack {
                                Text("Tune aggressiveness without a rebuild. Changes take effect immediately — the cached model session is invalidated on save.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Reset to default") {
                                    settings.aiCleanupPrompt = AppSettings.defaultAICleanupPrompt
                                }
                                .font(.caption)
                            }
                        }
                    }

                    Section("Per-app cleanup profiles") {
                        Text("Append an extra instruction based on the app you were dictating into. First matching regex wins.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(Array(settings.aiCleanupAppProfiles.keys.sorted()), id: \.self) { pattern in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pattern)
                                        .font(.system(.callout, design: .monospaced))
                                    Text(settings.aiCleanupAppProfiles[pattern] ?? "")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button {
                                    var next = settings.aiCleanupAppProfiles
                                    next.removeValue(forKey: pattern)
                                    settings.aiCleanupAppProfiles = next
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button("Reset to defaults") {
                            settings.aiCleanupAppProfiles = AppSettings.defaultAICleanupAppProfiles
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Clipboard

private struct ClipboardSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var showingAlfredImport = false
    @State private var alfredImportLimit: Int = 500
    @State private var alfredResult: ClipboardManager.AlfredImportResult?

    var body: some View {
        Form {
            Section {
                Toggle("Keep a clipboard history", isOn: $settings.clipboardEnabled)
                Text("Passwords and transient clips are always skipped. Off by default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Save dictations to clipboard history", isOn: $settings.saveDictationsToClipboard)
                Text("Every completed dictation lands in the clipboard picker so you can re-paste later. Turning this off keeps the picker focused on clips you explicitly copied.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Retention") {
                Picker("Keep clips from", selection: $settings.clipboardRetention) {
                    ForEach(AppSettings.ClipboardRetention.allCases) { retention in
                        Text(retention.displayName).tag(retention)
                    }
                }
                Picker("Max items", selection: $settings.clipboardCapacity) {
                    ForEach([50, 100, 250, 500, 1000, 2500, 5000, 10_000, 25_000, 50_000, 100_000], id: \.self) { cap in
                        Text(cap.formatted()).tag(cap)
                    }
                }
                Text(
                    "Pinned clips are kept forever, regardless of retention. " +
                    "Larger caps use more disk — a few MB per 1000 text clips, more if you save images. " +
                    "At 100K, expect ~50-200 MB of plist storage and a slower launch."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Import from Alfred") {
                HStack {
                    Text("Bring over your Alfred clipboard history.")
                    Spacer()
                    Button("Import from Alfred…") {
                        alfredResult = nil
                        showingAlfredImport = true
                    }
                }
                if let result = alfredResult {
                    if let error = result.errorMessage {
                        Text(error).font(.caption).foregroundColor(.red)
                    } else {
                        Text("Imported \(result.imported) clip\(result.imported == 1 ? "" : "s") · skipped \(result.skipped) (duplicates or outside retention window).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Section("Danger zone") {
                Button("Clear clipboard history") {
                    // Confirm before destroying. Without this, a single
                    // accidental click (or a SwiftUI re-render firing the
                    // action) wipes the entire history with no undo.
                    let alert = NSAlert()
                    alert.messageText = "Clear clipboard history?"
                    alert.informativeText = "Removes \(ClipboardManager.shared.items.count) item(s). Pinned items are kept. This can't be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        ClipboardManager.shared.clear()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAlfredImport) {
            AlfredImportSheet(
                limit: $alfredImportLimit,
                onImport: {
                    alfredResult = ClipboardManager.shared.importFromAlfred(limit: alfredImportLimit)
                    showingAlfredImport = false
                },
                onCancel: { showingAlfredImport = false }
            )
        }
    }
}

private struct AlfredImportSheet: View {
    @Binding var limit: Int
    let onImport: () -> Void
    let onCancel: () -> Void

    private let presets = [100, 500, 1000, 5000, 10_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Alfred").font(.headline)
            Text("Pulls the most recent text clips from `~/Library/Application Support/Alfred/Databases/clipboard.alfdb`. Duplicates and items outside your retention window are skipped.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("How many recent clips?", selection: $limit) {
                ForEach(presets, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Import") { onImport() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Screenshot

private struct ScreenshotSettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Enable screen capture feature", isOn: $settings.screenshotEnabled)
                Text("Hides the Capture command from the menu when off. Screen Recording permission is only requested the first time you capture.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("After capture") {
                Toggle("Auto-copy to clipboard", isOn: $settings.screenshotAutoCopy)
                Toggle("Auto-save to disk", isOn: $settings.screenshotAutoSave)
                Toggle("Skip annotation editor", isOn: $settings.screenshotSkipEditor)
                Toggle("Reveal saved file in Finder", isOn: $settings.screenshotRevealInFinder)
                    .disabled(!settings.screenshotAutoSave)
            }
            Section("Save location") {
                Picker("Save to", selection: $settings.screenshotSaveLocation) {
                    ForEach(AppSettings.ScreenshotSaveLocation.allCases) { loc in
                        Text(loc.displayName).tag(loc)
                    }
                }
                LabeledContent("Subfolder") {
                    TextField(
                        text: $settings.screenshotSubfolderName,
                        prompt: Text("Katib Screenshots")
                    ) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Text("Screenshots save into this subfolder of your chosen location (created automatically). Clear the field to save directly in the parent folder.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

private struct PermissionsSettingsPane: View {
    @ObservedObject var hotkeyManager: HotkeyManager
    @State private var microphoneGranted: Bool = true
    @State private var speechGranted: Bool = true

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "Accessibility",
                    detail: "Detect the hotkey and paste transcribed text.",
                    granted: hotkeyManager.hasAccessibilityPermission,
                    pane: .accessibility,
                    requestAction: { hotkeyManager.requestAccessibilityPermission() }
                )
                permissionRow(
                    title: "Microphone",
                    detail: "Capture audio when you hold the hotkey.",
                    granted: microphoneGranted,
                    pane: .microphone,
                    requestAction: { requestMicrophone() }
                )
                permissionRow(
                    title: "Speech Recognition",
                    detail: "On-device transcription via Apple's Speech framework.",
                    granted: speechGranted,
                    pane: .speechRecognition,
                    requestAction: { requestSpeech() }
                )
                permissionRow(
                    title: "Screen Recording",
                    detail: "Needed only for the Capture feature — prompted on first use.",
                    granted: CGPreflightScreenCaptureAccess(),
                    pane: .screenRecording,
                    requestAction: { _ = CGRequestScreenCaptureAccess() }
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        pane: SettingsPane,
        requestAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").font(.caption).foregroundColor(.secondary)
            } else {
                Button("Grant") {
                    requestAction()
                    pane.open()
                }
            }
        }
    }

    private func refresh() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        hotkeyManager.checkAccessibilityPermission()
    }

    private func requestMicrophone() {
        // The completion handler runs on TCC's dispatch queue, not main.
        // Marking it @Sendable forces the closure to be non-isolated, so
        // Swift 6's strict concurrency check doesn't crash when TCC invokes
        // it. The Task hop inside re-enters MainActor for the UI refresh.
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in
            Task { @MainActor in refresh() }
        }
    }

    private func requestSpeech() {
        SFSpeechRecognizer.requestAuthorization { @Sendable _ in
            Task { @MainActor in refresh() }
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var showingClearHistoryConfirm = false
    @State private var historyCleared = false

    var body: some View {
        Form {
            Section("Code mode") {
                LabeledContent("Enable in apps matching") {
                    TextField(
                        text: $settings.codeModeAppPattern,
                        prompt: Text(AppSettings.defaultCodeModeAppPattern)
                    ) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 320)
                }
                Text("""
                    When the frontmost app's bundle ID matches this regex, words like "dash", "slash", "dot", \
                    "underscore" between identifier tokens collapse into punctuation — "acme dash api" → \
                    acme-api. Stopwords (the, to, a, I, …) on either side prevent the collapse, so normal \
                    speech stays intact. Clear the field to disable everywhere.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset to default") {
                    settings.codeModeAppPattern = AppSettings.defaultCodeModeAppPattern
                }
                .font(.caption)
            }

            Section("Debug") {
                Toggle("Log full transcript at each pipeline stage", isOn: $settings.debugTranscripts)
                Text("""
                    Writes raw / corrected / code-mode / AI-raw / polished text to \
                    ~/Library/Logs/Katib/katib.log so you can see exactly what each stage produced. Local \
                    only — nothing leaves your Mac. Off by default.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Data") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear transcription stats")
                        Text("Today's count + word totals. Katib stores no transcription content on disk — this just wipes the per-day tallies.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if historyCleared {
                        Text("Cleared").foregroundColor(.secondary).font(.caption)
                    } else {
                        Button("Clear") { showingClearHistoryConfirm = true }
                    }
                }
                HStack {
                    Text("Reveal correction files")
                    Spacer()
                    Button("Reveal") { revealCorrectionFolder() }
                }
                HStack {
                    Text("Open log")
                    Spacer()
                    Button("Open") { openLogFile() }
                }
            }
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(versionString).foregroundColor(.secondary).monospacedDigit()
                }
                Link("View source on GitHub",
                     destination: URL(string: "https://github.com/sevensevensix776/katib")!)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear transcription stats?",
                            isPresented: $showingClearHistoryConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes ~/Library/Application Support/VoiceTools/history.jsonl. Counts reset to zero.")
        }
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func clearHistory() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let historyURL = appSupport.appendingPathComponent("VoiceTools/history.jsonl")
        try? FileManager.default.removeItem(at: historyURL)
        historyCleared = true
        Logger.shared.log("History cleared from Settings")
    }

    private func revealCorrectionFolder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("VoiceTools")
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func openLogFile() {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Katib")
        let logFile = logsDir.appendingPathComponent("katib.log")
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.open(logFile)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([logsDir])
        }
    }
}
