import SwiftUI
import AppKit
import Speech
import AVFoundation
import KatibCore
import KatibDictation
import KatibClipboard
import KatibScreenshot
import KatibWindow

/// Popover shown when the menu bar icon is clicked. Accordion layout: each
/// feature gets its own collapsible section so the popover stays compact but
/// every surface is one click away. Expanded state persists to UserDefaults.
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

    enum Section: String, CaseIterable, Identifiable {
        // Screenshots + Windows were in the accordion but didn't earn their
        // space — Screenshots just showed the save location (already in
        // Settings), Windows showed inert icons + a tip line. Both removed
        // from the menu bar popover. The features themselves still work
        // via hotkeys; Settings → Shortcuts is the one surface for that.
        case dictate, clipboard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dictate: return "Dictate"
            case .clipboard: return "Clipboard"
            }
        }
        var symbol: String {
            switch self {
            case .dictate: return "waveform"
            case .clipboard: return "doc.on.clipboard"
            }
        }
    }

    let openSettings: () -> Void
    let openCorrections: () -> Void
    let onRePasteLast: () -> Void
    let onUndoLast: () -> Void

    @State private var expanded: Set<Section> = MenuBarView.loadExpanded()
    @State private var copyFeedbackID: UUID?
    @State private var correctionsHover = false
    /// Fixed start so the header owl keeps its blink rhythm across popover opens.
    private let owlEpoch = Date(timeIntervalSinceReferenceDate: 0)

    private var lastTranscription: String? { popoverState.lastTranscription }
    private var microphoneGranted: Bool { popoverState.microphoneGranted }
    private var speechGranted: Bool { popoverState.speechGranted }

    private var todayStats: (count: Int, words: Int) { history.todayStats() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if updateChecker.available {
                updateBanner
            }

            permissionStack

            ForEach(Section.allCases) { section in
                accordionRow(section)
            }

            footer
        }
        .padding(14)
        .frame(minWidth: 360, idealWidth: 360)
        .tint(AppColors.bronze)
    }

    // MARK: - Header + chrome

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            OwlSpriteView(mood: .listening(speaking: false), moodStartedAt: owlEpoch, paused: !popoverState.isVisible)
            VStack(alignment: .leading, spacing: 3) {
                Text("Katib").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(transcriber.isReady ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(transcriber.isReady ? "Ready" : transcriber.statusMessage)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(action: openSettings) {
                    Image(systemName: "gearshape").font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Open Katib settings")
                .keyboardShortcut(",", modifiers: .command)
                HStack(spacing: 6) {
                    StatPill(value: todayStats.count, symbol: "waveform").help("Dictations today")
                    StatPill(value: todayStats.words, symbol: "text.word.spacing").help("Words dictated today")
                }
            }
        }
    }

    private var updateBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundColor(AppColors.bronze)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available — \(updateChecker.latestVersion ?? "?")")
                    .font(.caption).fontWeight(.medium)
                if let notes = updateChecker.latestNotes, !notes.isEmpty {
                    Text(notes).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button("Download") {
                if let url = updateChecker.latestURL { NSWorkspace.shared.open(url) }
            }
            .font(.caption)
        }
        .padding(8)
        .background(AppColors.bronze.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var permissionStack: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        }
    }

    private func permissionRow(label: String, detail: String, action: @escaping () -> Void, pane: SettingsPane) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).fontWeight(.medium)
                Text(detail).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button("Grant") {
                action()
                pane.open()
            }
            .font(.caption)
        }
    }

    // MARK: - Accordion

    @ViewBuilder
    private func accordionRow(_ section: Section) -> some View {
        let isOpen = expanded.contains(section)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(section)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppColors.bronzeHighlight)
                        .frame(width: 22, height: 22)
                        .background(AppColors.bronze.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    Text(section.title).font(.callout).fontWeight(.semibold)
                    if let badge = badge(for: section) {
                        Text(badge)
                            .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(10)
            }
            .buttonStyle(.plain)

            if isOpen {
                sectionContent(section)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func toggle(_ section: Section) {
        if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
        persistExpanded()
    }

    private func badge(for section: Section) -> String? {
        switch section {
        case .dictate: return nil
        case .clipboard:
            return settings.clipboardEnabled ? "\(clipboard.items.count)" : "off"
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: Section) -> some View {
        switch section {
        case .dictate: dictateContent
        case .clipboard: clipboardContent
        }
    }

    // MARK: - Section content

    @ViewBuilder
    private var dictateContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = lastTranscription {
                lastTranscriptionSection(text)
            } else {
                Text("Hold **\(settings.hotkeySide.displayName)** anywhere, speak, release. Double-tap to re-paste.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: openCorrections) {
                HStack(spacing: 6) {
                    Image(systemName: "character.book.closed").foregroundColor(.secondary)
                    Text("Edit corrections").font(.caption)
                    Spacer()
                    Text("\(corrections.totalCount)").foregroundColor(.secondary).font(.caption.monospacedDigit())
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                }
                .padding(.vertical, 5).padding(.horizontal, 6)
                .background(correctionsHover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { correctionsHover = $0 }
            .accessibilityLabel("Edit corrections. \(corrections.totalCount) total.")
        }
    }

    @ViewBuilder
    private var clipboardContent: some View {
        if settings.clipboardEnabled {
            ClipboardPane(clipboard: clipboard)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clipboard history is off.").font(.caption).foregroundColor(.secondary)
                Button("Turn on") { settings.clipboardEnabled = true }.font(.caption)
            }
        }
    }

    // MARK: - Last transcription sub-section

    private func lastTranscriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppColors.bronze)
                    .frame(width: 3)
                Text(text)
                    .font(.system(size: 12)).lineLimit(3)
                    .foregroundColor(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 6) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    let id = UUID()
                    copyFeedbackID = id
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        if copyFeedbackID == id { copyFeedbackID = nil }
                    }
                } label: {
                    Label(copyFeedbackID == nil ? "Copy" : "Copied!",
                          systemImage: copyFeedbackID == nil ? "doc.on.doc" : "checkmark")
                }
                Button(action: onRePasteLast) { Label("Paste again", systemImage: "arrow.uturn.forward") }
                Button(action: onUndoLast) { Label("Undo", systemImage: "arrow.uturn.backward") }
                Spacer()
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Hold")
                .font(.caption).foregroundColor(.secondary)
            Text(settings.hotkeySide.displayName)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            Text("to dictate")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.plain).foregroundColor(.secondary).font(.caption)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Persistence

    private static let expandedKey = "menuExpandedSections"

    private static func loadExpanded() -> Set<Section> {
        if let stored = UserDefaults.standard.stringArray(forKey: expandedKey) {
            return Set(stored.compactMap(Section.init(rawValue:)))
        }
        return [.dictate]
    }

    private func persistExpanded() {
        let raw = expanded.map(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.expandedKey)
    }
}

// MARK: - Small pieces

/// Today's count with its icon, in a capsule.
private struct StatPill: View {
    let value: Int
    let symbol: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text("\(value)").font(.caption2.monospacedDigit().weight(.medium))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// Bronze capsule button. Custom because the system bordered style turns
/// near-invisible on the glass popover.
private struct ChipButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundColor(AppColors.bronzeHighlight)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(
                AppColors.bronze.opacity(configuration.isPressed ? 0.32 : hovering ? 0.24 : 0.16),
                in: Capsule()
            )
            .overlay(Capsule().stroke(AppColors.bronze.opacity(0.35), lineWidth: 0.5))
            .onHover { hovering = $0 }
    }
}
