import SwiftUI
import AppKit
import Combine
import KatibCore

// MARK: - State

public enum IndicatorState {
    case recording
    case finalizing
    case success(String, heading: String = "Pasted")
    case error(String)
}

// MARK: - Window Controller

@MainActor
public final class LiveIndicatorWindowController {
    public static let shared = LiveIndicatorWindowController()

    private var window: NSWindow?
    private var viewModel = LiveIndicatorViewModel()

    /// Pre-build the window + SwiftUI view hierarchy up-front so the first
    /// `show()` call is fast. We have to actually make the window visible
    /// once — SwiftUI defers view-tree construction until the hosting view
    /// is onscreen. A `createWindow()` alone isn't enough; the render
    /// pass only happens on `orderFront`. We show invisibly (alpha 0) off
    /// the user's main display, let SwiftUI build, then order out.
    public func prewarm() {
        guard window == nil else { return }
        createWindow()
        guard let window else { return }
        window.alphaValue = 0
        // Park well offscreen so any flash isn't visible on any monitor.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.frame.maxX + 2000, y: -2000))
        }
        window.orderFront(nil)
        // Force a synchronous layout + draw so SwiftUI actually builds its
        // view tree now — not lazily on the first real show(). orderFront
        // alone schedules a draw but doesn't wait for it, which is why the
        // earlier prewarm attempts still let the render cost land on
        // dictation #1.
        window.display()
        if let hosting = window.contentView as? NSView {
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        window.orderOut(nil)
    }

    /// Bottom-right of the screen the cursor is on, so with several monitors
    /// the HUD shows up where you are looking. Re-read on every show.
    static func restingOrigin(cursor: NSPoint = NSEvent.mouseLocation) -> NSPoint? {
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return nil }
        return NSPoint(x: frame.maxX - 416, y: frame.minY + 16)
    }

    /// Bumped on every show, so a hide timer from the previous dictation
    /// cannot hide the next one.
    private var showGeneration = 0

    public func show(transcriber: StreamingTranscriber) {
        showGeneration += 1
        viewModel.transcriber = transcriber
        viewModel.state = .recording
        viewModel.recordingStartTime = Date()
        viewModel.stateChangedAt = Date()

        if window == nil {
            createWindow()
        }
        if let origin = Self.restingOrigin() {
            window?.setFrameOrigin(origin)
        }

        window?.alphaValue = 0
        window?.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window?.animator().alphaValue = 1
        }
    }

    public func updateState(_ state: IndicatorState) {
        viewModel.state = state
        viewModel.stateChangedAt = Date()

        switch state {
        case .success, .error:
            let generation = showGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.showGeneration == generation else { return }
                self.hide()
            }
        default:
            break
        }
    }

    public func hide() {
        guard let window else { return }
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: {
            // AppKit runs this on the main thread. A new show() during the
            // fade owns the window now.
            MainActor.assumeIsolated {
                guard self.showGeneration == generation else { return }
                window.orderOut(nil)
                self.viewModel.transcriber = nil
            }
        })
    }

    private func createWindow() {
        let view = LiveIndicatorView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        self.window = window
    }
}

// MARK: - View Model

@MainActor
class LiveIndicatorViewModel: ObservableObject {
    @Published var state: IndicatorState = .recording
    @Published var transcriber: StreamingTranscriber?
    @Published var recordingStartTime: Date?
    /// When `state` last changed, so the owl's one-shot moves start from the top.
    @Published var stateChangedAt = Date()
}

// MARK: - Main View

struct LiveIndicatorView: View {
    @ObservedObject var viewModel: LiveIndicatorViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OwlMascot(viewModel: viewModel)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 0) {
                // Top bar: status + waveform/timer
                topBar
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                // Bottom: scrolling live text
                textArea
                    .padding(.bottom, 10)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(width: 400, height: 150)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Top Bar

    @ViewBuilder
    private var topBar: some View {
        switch viewModel.state {
        case .recording:
            if let transcriber = viewModel.transcriber {
                HStack(spacing: 8) {
                    // Waveform
                    WaveformView(transcriber: transcriber)
                        .frame(width: 100, height: 20)

                    Spacer()

                    // Duration timer
                    if let start = viewModel.recordingStartTime {
                        DurationTimer(startTime: start)
                    }
                }
            }
        case .finalizing:
            HStack(spacing: 8) {
                SpinnerView()
                    .frame(width: 12, height: 12)
                Text("Processing...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
        case .success(_, let heading):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text(heading)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green.opacity(0.9))
                Spacer()
            }
        case .error:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
                Text("Error")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.9))
                Spacer()
            }
        }
    }

    // MARK: - Text Area

    @ViewBuilder
    private var textArea: some View {
        switch viewModel.state {
        case .recording:
            if let transcriber = viewModel.transcriber {
                ScrollingTextView(transcriber: transcriber)
            }
        case .success(let text, _):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error(let msg):
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.orange.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    // MARK: - Background (dark charcoal + bronze)

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.16, blue: 0.15),
                        Color(red: 0.1, green: 0.08, blue: 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppColors.bronze.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Scrolling Live Text

struct ScrollingTextView: View {
    @ObservedObject var transcriber: StreamingTranscriber

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if transcriber.liveText.isEmpty {
                        Text("Listening...")
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        Text(transcriber.liveText)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("text")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: transcriber.liveText) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("text", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Owl

/// Picks the owl's mood from the HUD state. "Speaking" holds for a moment
/// after the last loud buffer so the scribble does not stutter between words.
struct OwlMascot: View {
    @ObservedObject var viewModel: LiveIndicatorViewModel
    @State private var lastLoudAt = Date.distantPast
    @State private var speaking = false
    @State private var speakingChangedAt = Date()

    private static let loudLevel: Float = 0.12
    private static let hangover: TimeInterval = 0.6

    var body: some View {
        Group {
            if let transcriber = viewModel.transcriber {
                sprite.onReceive(transcriber.$audioLevel) { level in
                    let now = Date()
                    if level >= Self.loudLevel { lastLoudAt = now }
                    let isSpeaking = now.timeIntervalSince(lastLoudAt) < Self.hangover
                    if isSpeaking != speaking {
                        speaking = isSpeaking
                        speakingChangedAt = now
                    }
                }
            } else {
                sprite
            }
        }
    }

    private var sprite: some View {
        OwlSpriteView(
            mood: mood,
            moodStartedAt: isListening ? max(speakingChangedAt, viewModel.stateChangedAt) : viewModel.stateChangedAt,
            paused: viewModel.transcriber == nil
        )
    }

    private var isListening: Bool {
        if case .recording = viewModel.state { return true }
        return false
    }

    private var mood: OwlMood {
        switch viewModel.state {
        case .recording: return .listening(speaking: speaking)
        case .finalizing: return .thinking
        case .success: return .done
        case .error: return .failed
        }
    }
}

// MARK: - Duration Timer

struct DurationTimer: View {
    let startTime: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(format(elapsed))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startTime)
            }
    }

    private func format(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        let tenths = Int((t.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", m, s, tenths)
    }
}

// MARK: - Waveform (bronze bars responding to audio level)

struct WaveformView: View {
    @ObservedObject var transcriber: StreamingTranscriber
    @State private var levels: [CGFloat] = Array(repeating: 0.05, count: 24)

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<levels.count, id: \.self) { i in
                    let height = max(3, levels[i] * geo.size.height)
                    let opacity = 0.5 + (levels[i] * 0.5)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(red: 0.85, green: 0.65, blue: 0.4).opacity(opacity))
                        .frame(width: 2, height: height)
                        .animation(.easeOut(duration: 0.08), value: levels[i])
                }
            }
            .frame(height: geo.size.height)
        }
        .onChange(of: transcriber.audioLevel) { _, newLevel in
            levels.removeFirst()
            let adjusted = max(0.08, min(1.0, CGFloat(newLevel) * 1.5 + CGFloat.random(in: -0.05...0.05)))
            levels.append(adjusted)
        }
    }
}

// MARK: - Spinner

struct SpinnerView: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(
                AngularGradient(
                    colors: [
                        Color(red: 0.85, green: 0.65, blue: 0.4).opacity(0.1),
                        Color(red: 0.85, green: 0.65, blue: 0.4).opacity(0.9)
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
