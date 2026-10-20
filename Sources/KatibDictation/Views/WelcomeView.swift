import SwiftUI
import KatibCore
import AVFoundation
import Speech
import ApplicationServices
import AppKit

/// Multi-step first-run onboarding modeled on muesli: Welcome → Permissions →
/// Dictation Test → Done. Each step auto-advances when its precondition is met.
/// Permissions are polled every 1s so flipping a toggle in System Settings
/// transitions the UI without the user having to come back and click.
@MainActor
public struct WelcomeView: View {
    public let hotkeySide: AppSettings.HotkeySide
    public let onDone: () -> Void
    private var hotkeyName: String { hotkeySide.displayName }

    /// Set by the host AppDelegate before showing the welcome window. While
    /// non-nil, the post-release dictation pipeline routes the transcript here
    /// instead of pasting. The Dictation Test step uses this to preview what
    /// was heard without spraying text into whatever app happens to be
    /// frontmost.
    public let installTestCallback: (((String) -> Void)?) -> Void
    /// Same idea for the screenshot step: called when a capture lands.
    public let installScreenshotCallback: ((() -> Void)?) -> Void

    @StateObject private var state = OnboardingState()
    /// Lights the key in the keyboard drawing while Katib is recording, and
    /// says so while the speech model is still getting ready.
    @ObservedObject private var transcriber: StreamingTranscriber

    public init(
        hotkeySide: AppSettings.HotkeySide,
        transcriber: StreamingTranscriber,
        installTestCallback: @escaping (((String) -> Void)?) -> Void,
        installScreenshotCallback: @escaping ((() -> Void)?) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.hotkeySide = hotkeySide
        self.transcriber = transcriber
        self.installTestCallback = installTestCallback
        self.installScreenshotCallback = installScreenshotCallback
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
            footer
        }
        .frame(width: 560, height: 640)
        .background(.regularMaterial)
        .onAppear {
            state.refresh()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            state.refresh()
        }
        .onChange(of: state.step) { _, newStep in
            if newStep == .test {
                installTestCallback { transcript in
                    Task { @MainActor in state.recordTestTranscript(transcript) }
                }
            } else {
                installTestCallback(nil)
            }
            if newStep == .screenshot {
                installScreenshotCallback {
                    Task { @MainActor in state.screenshotTaken = true }
                }
            } else {
                installScreenshotCallback(nil)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(AppColors.bronze)
            Text(state.step.title)
                .font(.title)
                .fontWeight(.semibold)
            if let subtitle = state.step.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            stepDots
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingState.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == state.step ? AppColors.bronze : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case .welcome: welcomeContent
        case .permissions: permissionsContent
        case .test: testContent
        case .screenshot: screenshotContent
        case .done: doneContent
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            KeyboardHint(side: hotkeySide)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
            usageStep(number: 1,
                      title: "Hold **\(hotkeyName)**",
                      detail: "Anywhere on your Mac. Katib only listens while you hold — release to stop.")
            usageStep(number: 2,
                      title: "Speak",
                      detail: "Natural pace. Transcription runs on your Mac — no cloud, no recording.")
            usageStep(number: 3,
                      title: "Release",
                      detail: "Text pastes into whatever app is frontmost. Like typing, but faster.")
            usageStep(number: 4,
                      title: "Double-tap to repeat · Esc to cancel",
                      detail: "Quick double-tap of \(hotkeyName) re-pastes the last transcription. Press Esc mid-recording to abort.")
            tip
        }
    }

    private var permissionsContent: some View {
        VStack(spacing: 10) {
            permissionRow(
                title: "Microphone",
                detail: "So Katib can hear what you say.",
                granted: state.micGranted,
                action: { state.requestMic() }
            )
            permissionRow(
                title: "Speech Recognition",
                detail: "Apple's on-device model that turns audio into text. Stays on your Mac.",
                granted: state.speechGranted,
                action: { state.requestSpeech() }
            )
            permissionRow(
                title: "Accessibility",
                detail: "Lets Katib paste at your cursor and intercept the hotkey globally.",
                granted: state.accessibilityGranted,
                action: { state.requestAccessibility() }
            )
            permissionRow(
                title: "Screen Recording",
                detail: "Needed for ⇧⌘3 / ⇧⌘4 screenshot capture and annotation.",
                granted: state.screenRecordingGranted,
                action: { state.requestScreenRecording() }
            )
            if !state.allGranted {
                Text("Toggle each in System Settings, then come back — this screen advances when all four are on.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        }
    }

    private var testContent: some View {
        VStack(spacing: 18) {
            Text("Hold **\(hotkeyName)** anywhere — say a sentence or two — release.")
                .font(.body)
                .multilineTextAlignment(.center)
            KeyboardHint(side: hotkeySide, held: transcriber.isRecording)
            Text(testStatus)
                .font(.caption)
                .foregroundColor(transcriber.isRecording ? AppColors.bronze : .secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 110)
                if let transcript = state.testTranscript, !transcript.isEmpty {
                    ScrollView {
                        Text(transcript)
                            .font(.body)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Your test transcript will appear here.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            Text("Nothing pastes during this test — just confirming the pipeline works.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var testStatus: String {
        if !transcriber.isReady { return "Getting speech recognition ready: \(transcriber.statusMessage)" }
        if transcriber.isRecording { return "Listening… release to finish." }
        return "Waiting for the key…"
    }

    private var screenshotContent: some View {
        VStack(spacing: 18) {
            Text("Press **⇧⌘3**, then drag over any part of the screen.")
                .font(.body)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Image(systemName: state.screenshotTaken ? "checkmark.circle.fill" : "camera.viewfinder")
                    .font(.title2)
                    .foregroundColor(state.screenshotTaken ? .green : AppColors.bronze)
                Text(state.screenshotTaken ? "Got it. The picture is on your clipboard." : "Waiting for a screenshot…")
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            Text("⇧⌘3 copies a screenshot; ⇧⌘4 opens it in an editor first. Katib takes these keys over from the Mac's "
                 + "own screenshot tool. You can change them in Settings → Shortcuts.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            doneRow(symbol: "command.square", text: "**⌘Space** — command palette: every Katib action + apps + files")
            doneRow(symbol: "doc.on.clipboard", text: "**⇧⌃⌘V** — clipboard history picker")
            doneRow(symbol: "camera.viewfinder", text: "**⇧⌘3 / ⇧⌘4** — screenshots straight to clipboard or annotate first")
            doneRow(symbol: "rectangle.split.2x1", text: "Window snap — say _\"split left\"_ or _\"maximize\"_ mid-dictation")
            doneRow(symbol: "gearshape", text: "Tune everything in the menu bar → Settings · the **ك** lives in your menu bar")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if state.step != .welcome {
                Button("Back") { state.back() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if state.step == .screenshot && !state.screenshotTaken {
                Button("Skip") { state.advance() }
                    .buttonStyle(.link)
                    .padding(.trailing, 8)
            }
            Button {
                if state.step == .done {
                    onDone()
                } else {
                    state.advance()
                }
            } label: {
                Text(state.primaryButtonLabel).frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.bronze)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!state.canAdvance)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Row helpers

    private func usageStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(AppColors.bronze.opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay(
                    Text("\(number)")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(AppColors.bronze)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(.init(title)).font(.body)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(granted ? .green : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant", action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func doneRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundColor(AppColors.bronze)
                .frame(width: 24)
            Text(.init(text)).font(.callout)
            Spacer()
        }
    }

    private var tip: some View {
        VStack(spacing: 6) {
            Text("Tip")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(AppColors.bronze)
            Text("Teach Katib your names and terms in the menu bar → Edit corrections.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }
}

// MARK: - State

@MainActor
final class OnboardingState: ObservableObject {
    enum Step: Int, CaseIterable, Equatable {
        case welcome, permissions, test, screenshot, done

        var title: String {
            switch self {
            case .welcome: return "Welcome to Katib"
            case .permissions: return "Grant Permissions"
            case .test: return "Try a Dictation"
            case .screenshot: return "Try a Screenshot"
            case .done: return "You're Set"
            }
        }

        var subtitle: String? {
            switch self {
            case .welcome: return "كاتب — The Scribe"
            case .permissions: return "Four one-time prompts. Each opens its System Settings panel."
            case .test, .screenshot: return nil
            case .done: return "A handful of other things Katib does, while you're here."
            }
        }
    }

    @Published var step: Step = .welcome
    @Published var micGranted = false
    @Published var speechGranted = false
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var testTranscript: String?
    @Published var screenshotTaken = false

    var allGranted: Bool { micGranted && speechGranted && accessibilityGranted && screenRecordingGranted }

    var canAdvance: Bool {
        switch step {
        case .welcome: return true
        case .permissions: return allGranted
        case .test: return testTranscript != nil
        case .screenshot: return screenshotTaken
        case .done: return true
        }
    }

    var primaryButtonLabel: String {
        switch step {
        case .welcome: return "Get Started"
        case .permissions: return allGranted ? "Continue" : "Waiting for grants…"
        case .test: return testTranscript == nil ? "Waiting for dictation…" : "Sounds Good"
        case .screenshot: return screenshotTaken ? "Continue" : "Waiting for a screenshot…"
        case .done: return "Start Using Katib"
        }
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        if step == .test {
            testTranscript = nil
        }
        if step == .screenshot {
            screenshotTaken = false
        }
    }

    func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    func recordTestTranscript(_ text: String) {
        testTranscript = text
    }

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    // MARK: - Permission requests

    /// Programmatic mic prompt. `@Sendable` empty completion is mandatory here
    /// — TCC fires the callback on a non-main queue, and without `@Sendable`
    /// Swift 6 infers @MainActor isolation from the call site and `SIGTRAP`s
    /// via `dispatch_assert_queue_fail`. Same fix MenuBarView uses.
    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in }
        openSettingsIfDenied(.microphone,
                             status: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    func requestSpeech() {
        SFSpeechRecognizer.requestAuthorization { @Sendable _ in }
        openSettingsIfDenied(.speechRecognition,
                             status: SFSpeechRecognizer.authorizationStatus() == .authorized)
    }

    /// Triggers the OS Accessibility prompt. Uses the literal CFString value
    /// of `kAXTrustedCheckOptionPrompt` to dodge the Swift 6 non-Sendable
    /// global-CFString warning; the string is part of the ABI and won't change.
    /// Unlike `AXIsProcessTrusted()` (passive), this surfaces the system dialog
    /// the first time.
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !AXIsProcessTrusted() {
            SettingsPane.accessibility.open()
        }
    }

    /// Triggers the OS Screen Recording prompt the first time. After the user
    /// flips the toggle in System Settings, `CGPreflightScreenCaptureAccess`
    /// will return true on the next poll and the row auto-advances.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        if !CGPreflightScreenCaptureAccess() {
            SettingsPane.screenRecording.open()
        }
    }

    private func openSettingsIfDenied(_ pane: SettingsPane, status: Bool) {
        guard !status else { return }
        pane.open()
    }
}
