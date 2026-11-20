import SwiftUI
import AppKit
import Speech
import AVFoundation
import KatibCore
import KatibDictation
import KatibClipboard
import KatibScreenshot
import KatibWindow

/// Popover shown when the menu bar icon is clicked. Direction A, "776 Ledger"
/// (2026-11-20): the layout lives in KatibCore's `PopoverLedgerView`; this
/// view feeds it live state and supplies the two slots that need managers
/// from this target (permission/update banners, the clipboard list).
/// The Clipboard row's open state persists to UserDefaults.
@MainActor
struct MenuBarView: View {
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var transcriber: StreamingTranscriber
    @ObservedObject var settings: AppSettings
    @ObservedObject var corrections: TextCorrectionEngine
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var popoverState: PopoverState
    @ObservedObject var clipboard: ClipboardManager
    let history: TranscriptionHistory

    let openSettings: () -> Void
    let openPermissions: () -> Void
    let openCorrections: () -> Void
    let onRePasteLast: () -> Void
    let onUndoLast: () -> Void

    @State private var clipboardOpen: Bool = MenuBarView.loadClipboardOpen()
    @State private var copyFeedbackID: UUID?
    @Environment(\.colorScheme) private var scheme

    private var microphoneGranted: Bool { popoverState.microphoneGranted }
    private var speechGranted: Bool { popoverState.speechGranted }
    private var p: Palette776 { .for(scheme) }

    var body: some View {
        let stats = history.todayStats()
        let now = Date()
        let data = PopoverLedgerData(
            ready: transcriber.isReady,
            statusText: transcriber.isReady ? "Ready" : transcriber.statusMessage,
            dateLabel: PopoverLedgerData.dateLabel(now),
            figures: LedgerFigures(dictations: stats.count, words: stats.words,
                                   spokenSeconds: stats.spokenSeconds, wpm: settings.typingWPM),
            typingWPM: settings.typingWPM,
            lastText: popoverState.lastTranscription,
            lastReceipt: popoverState.lastReceipt,
            lastTime: popoverState.lastDictationAt.map { PopoverLedgerData.timeLabel($0) },
            hotkeyName: settings.hotkeySide.displayName,
            correctionsCount: corrections.totalCount,
            clipboardBadge: settings.clipboardEnabled ? "\(clipboard.items.count)" : "off"
        )
        PopoverLedgerView(
            data: data,
            actions: PopoverLedgerActions(
                openSettings: openSettings,
                openCorrections: openCorrections,
                copyLast: copyLast,
                pasteAgain: onRePasteLast,
                undo: onUndoLast,
                quit: { NSApplication.shared.terminate(nil) }
            ),
            clipboardOpen: Binding(get: { clipboardOpen }, set: { clipboardOpen = $0; Self.persistClipboardOpen($0) }),
            copied: copyFeedbackID != nil
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if updateChecker.available { updateBanner }
                permissionStack
            }
        } clipboardBody: {
            clipboardContent
        }
    }

    // MARK: - Banners

    private var updateBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(p.purple).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Label776("Update available", color: p.purpleText)
                Text(updateChecker.latestVersion ?? "?").font(Type776.font(12.5)).foregroundColor(p.ink)
                if let notes = updateChecker.latestNotes, !notes.isEmpty {
                    Text(notes).font(Type776.font(11.5)).foregroundColor(p.muted).lineLimit(2)
                }
            }
            Spacer()
            Button("Download") {
                if let url = updateChecker.latestURL { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(Button776Style())
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var permissionStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hotkeyManager.hasAccessibilityPermission {
                permissionRow(
                    label: "Accessibility access required",
                    detail: "Needed so Katib can see the hotkey and paste text for you.",
                    action: { hotkeyManager.requestAccessibilityPermission() },
                    pane: .accessibility
                )
            }
            if !microphoneGranted {
                permissionRow(
                    label: "Microphone access required",
                    detail: "Needed to hear what you say.",
                    // The completion handler runs on TCC's dispatch queue
                    // (background, not main). Without `@Sendable` it's
                    // inferred @MainActor (we're inside a View body), and
                    // Swift 6's strict concurrency check fires
                    // `dispatch_assert_queue_fail` → SIGTRAP when TCC
                    // invokes it. The body is empty because permission
                    // state is observed via the BootstrapCoordinator poll.
                    action: { AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in } },
                    pane: .microphone
                )
            }
            if !speechGranted {
                permissionRow(
                    label: "Speech Recognition required",
                    detail: "Needed to turn audio into text on your Mac (stays on-device).",
                    action: { SFSpeechRecognizer.requestAuthorization { @Sendable _ in } },
                    pane: .speechRecognition
                )
            }
            if !popoverState.screenRecordingGranted {
                permissionRow(
                    label: "Screen Recording required",
                    detail: "Needed for ⇧⌘3 / ⇧⌘4 screenshots.",
                    action: { _ = CGRequestScreenCaptureAccess() },
                    pane: .screenRecording
                )
            }
            if !hotkeyManager.hasAccessibilityPermission || !microphoneGranted || !speechGranted || !popoverState.screenRecordingGranted {
                Button(action: openPermissions) {
                    Label776("Manage permissions", color: p.ink)
                        .overlay(alignment: .bottom) { Rectangle().fill(p.purple).frame(height: 1).offset(y: 3) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
    }

    private func permissionRow(label: String, detail: String, action: @escaping () -> Void, pane: SettingsPane) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(p.warn).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Type776.font(12.5, .medium)).foregroundColor(p.ink)
                Text(detail).font(Type776.font(11.5)).foregroundColor(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Grant") {
                action()
                pane.open()
            }
            .buttonStyle(Button776Style())
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Clipboard

    @ViewBuilder
    private var clipboardContent: some View {
        if settings.clipboardEnabled {
            ClipboardPane(clipboard: clipboard)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clipboard history is off.").font(Type776.font(12)).foregroundColor(p.muted)
                Button("Turn on") { settings.clipboardEnabled = true }.buttonStyle(Button776Style())
            }
        }
    }

    // MARK: - Last dictation

    private func copyLast() {
        guard let text = popoverState.lastTranscription else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let id = UUID()
        copyFeedbackID = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copyFeedbackID == id { copyFeedbackID = nil }
        }
    }

    // MARK: - Persistence

    /// Same key as the old accordion; it stored section names, and only
    /// "clipboard" is left to remember.
    private static let expandedKey = "menuExpandedSections"

    private static func loadClipboardOpen() -> Bool {
        UserDefaults.standard.stringArray(forKey: expandedKey)?.contains("clipboard") ?? false
    }

    private static func persistClipboardOpen(_ open: Bool) {
        UserDefaults.standard.set(open ? ["clipboard"] : [], forKey: expandedKey)
    }
}
