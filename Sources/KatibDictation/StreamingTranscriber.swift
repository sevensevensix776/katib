import Foundation
import Accelerate
@preconcurrency import Speech
@preconcurrency import AVFoundation
import CoreMedia
import KatibCore

/// Core streaming transcription engine using Apple's SpeechAnalyzer (WWDC 2025).
/// Hold the hotkey, speak, release — liveText accumulates as you go; stopRecording
/// returns the final string.
@MainActor
public final class StreamingTranscriber: ObservableObject {
    @Published public var isRecording = false
    @Published public var liveText = ""
    @Published public var audioLevel: Float = 0.0
    @Published public var statusMessage = "Starting..."
    @Published public var isReady = false

    public init() {}

    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var currentTranscriber: DictationTranscriber?
    private var resultsTask: Task<Void, Error>?

    /// Cached `bestAvailableAudioFormat` result. The speech-daemon IPC
    /// costs ~70ms; caching saves that on every dictation. Result depends
    /// on locale+preset (stable) and mic format (revalidated below). Set
    /// during setup(), reset on AVAudioEngineConfigurationChange.
    private var cachedOptimalFormat: AVAudioFormat?
    private var cachedMicSampleRate: Double = 0

    /// Long-lived engine kept solely so the audio session stays initialized.
    /// Created in setup() — first inputNode access lazily wakes the audio
    /// session (~60ms). Reusing it means startRecording's inputNode read is
    /// effectively free. Never started; the recording flow allocates its
    /// own engine for the actual capture.
    private var prewarmEngine: AVAudioEngine?

    private var recordingStartTime: Date?

    /// Tracks whether startRecording() has completed setup
    private var recordingSetupComplete = false

    /// Trace ID stamped into every dictation log line for the active
    /// recording cycle. Set on `startRecording`, cleared on stop. Lets
    /// `grep "DICT\[abcd1234\]"` pull the entire lifecycle of a single
    /// hotkey press out of the log.
    private var currentTraceID: String?

    /// Observer for `AVAudioEngine.configurationChangeNotification`. Fires
    /// when the audio device configuration changes mid-recording —
    /// Bluetooth headphones disconnect, USB mic unplugged, system sample
    /// rate changed. Without explicit handling the engine may produce
    /// silently empty buffers (codex's macOS 26 finding). We abort and
    /// log instead so the user's "I disconnected my headphones and got
    /// no transcript" report surfaces in the log.
    private var audioConfigObserver: NSObjectProtocol?

    /// Optional callback so AppDelegate can react to audio-config-induced
    /// aborts (e.g. hide the live indicator). Set externally.
    public var onAudioConfigAbort: (@MainActor () -> Void)?

    /// Words the recognizer should prefer, passed as `AnalysisContext.contextualStrings`.
    /// Set by the app before each recording from `TextCorrectionEngine.recognitionTerms`.
    public var contextualTerms: [String] = []

    // MARK: - Setup

    public func setup() async {
        statusMessage = "Requesting permissions..."
        Logger.shared.log("Setup: requesting speech auth...")

        let authStatus = await Self.requestSpeechAuthorization()
        guard authStatus == .authorized else {
            statusMessage = "Speech recognition not authorized"
            Logger.shared.log("ERROR: Speech auth denied (\(authStatus.rawValue))")
            return
        }
        Logger.shared.log("Setup: speech auth granted")

        let micGranted = await Self.requestMicPermission()
        guard micGranted else {
            statusMessage = "Microphone access denied"
            Logger.shared.log("ERROR: Microphone denied")
            return
        }
        Logger.shared.log("Setup: mic granted")

        statusMessage = "Checking speech model..."
        let probe = DictationTranscriber(
            locale: Locale(identifier: "en-US"),
            preset: .progressiveLongDictation
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                statusMessage = "Downloading speech model (first run only)..."
                Logger.shared.log("Downloading speech model...")
                try await request.downloadAndInstall()
                Logger.shared.log("Speech model downloaded")
            } else {
                Logger.shared.log("Speech model already available")
            }
        } catch {
            statusMessage = "Model download failed: \(error.localizedDescription)"
            Logger.shared.log("ERROR: Model download: \(error)")
            return
        }

        let prewarmStart = Date()
        let engine = AVAudioEngine()
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        prewarmEngine = engine
        cachedMicSampleRate = micFormat.sampleRate
        cachedOptimalFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [probe],
            considering: micFormat
        )
        let prewarmMs = Int(Date().timeIntervalSince(prewarmStart) * 1000)
        Logger.shared.log("Pre-warmed: mic=\(micFormat.sampleRate)Hz, optimal=\(cachedOptimalFormat?.sampleRate ?? 0)Hz (\(prewarmMs)ms)")

        isReady = true
        statusMessage = "Ready — hold Right Option to speak"
        Logger.shared.log("Setup complete — ready")
    }

    // MARK: - Recording (synchronous entry point, awaitable)

    public func startRecording(traceID: String = TraceID.new()) async throws {
        guard isReady, !isRecording else {
            Logger.shared.log("DICT[\(traceID)]: startRecording skipped (ready=\(isReady), recording=\(isRecording))")
            return
        }

        currentTraceID = traceID
        let startTime = Date()
        recordingStartTime = startTime
        recordingSetupComplete = false
        liveText = ""
        Logger.shared.log("DICT[\(traceID)]: startRecording begin")

        // DictationTranscriber is designed for direct speech-to-mic dictation
        // (vs SpeechTranscriber which is for podcasts/meetings/recordings)
        let transcriber = DictationTranscriber(
            locale: Locale(identifier: "en-US"),
            preset: .progressiveLongDictation
        )
        self.currentTranscriber = transcriber

        let engine = AVAudioEngine()
        self.audioEngine = engine
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        Logger.shared.log("DICT[\(traceID)]: mic format \(micFormat.sampleRate)Hz, \(micFormat.channelCount)ch")

        let optimalFormat: AVAudioFormat?
        if let cached = cachedOptimalFormat, cachedMicSampleRate == micFormat.sampleRate {
            optimalFormat = cached
            Logger.shared.log("DICT[\(traceID)]: optimalFormat from cache (\(cached.sampleRate)Hz)")
        } else {
            let formatStart = Date()
            optimalFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: micFormat
            )
            let formatMs = Int(Date().timeIntervalSince(formatStart) * 1000)
            Logger.shared.log("DICT[\(traceID)]: bestAvailableAudioFormat=\(optimalFormat?.sampleRate ?? 0)Hz (\(formatMs)ms, cache miss)")
            cachedOptimalFormat = optimalFormat
            cachedMicSampleRate = micFormat.sampleRate
        }

        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = cont

        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [transcriber]
        )
        self.analyzer = analyzer
        Logger.shared.log("startRecording: analyzer created")

        // Bias the recognizer toward dictionary names and jargon. DictationTranscriber
        // reads contextualStrings; SpeechTranscriber ignores them. Set before
        // any audio is fed. Advisory: on failure the session runs without hints.
        if !contextualTerms.isEmpty {
            let contextStart = Date()
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualTerms]
            do {
                try await analyzer.setContext(context)
                let ms = Int(Date().timeIntervalSince(contextStart) * 1000)
                Logger.shared.log("DICT[\(traceID)]: setContext \(contextualTerms.count) terms (\(ms)ms)")
            } catch {
                Logger.shared.log("DICT[\(traceID)]: setContext failed, no hints: \(error.localizedDescription)")
            }
        }

        // Accumulate results: finalized segments + current volatile segment
        // Results update liveText which is grabbed instantly on stop.
        resultsTask = Task { [weak self] in
            var finalizedText = ""
            var currentVolatile = ""
            var resultCount = 0
            var lastRangeStart: CMTime?
            var segmentCount = 0

            for try await result in transcriber.results {
                let text = String(result.text.characters)
                resultCount += 1

                if resultCount == 1 {
                    let firstResultMs = Int(Date().timeIntervalSince(startTime) * 1000)
                    Logger.shared.log("DICT[\(traceID)]: RESULT #1 (\(firstResultMs)ms after begin, \(text.count) chars, final=\(result.isFinal))")
                } else if resultCount.isMultiple(of: 20) {
                    Logger.shared.log("DICT[\(traceID)]: RESULT #\(resultCount) (\(text.count) chars, final=\(result.isFinal))")
                }

                // Detect new segment by time range change
                let isNewSegment: Bool
                if let lastStart = lastRangeStart {
                    isNewSegment = result.range.start != lastStart
                } else {
                    isNewSegment = false
                }

                if isNewSegment {
                    segmentCount += 1
                    if !currentVolatile.isEmpty {
                        let trimmed = currentVolatile.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            if !finalizedText.isEmpty { finalizedText += " " }
                            finalizedText += trimmed
                        }
                        Logger.shared.log("DICT[\(traceID)]: SEGMENT \(segmentCount) promoted (\(Logger.summarize(trimmed)))")
                        currentVolatile = ""
                    }
                }

                if result.isFinal {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        if !finalizedText.isEmpty { finalizedText += " " }
                        finalizedText += trimmed
                    }
                    currentVolatile = ""
                    Logger.shared.log("DICT[\(traceID)]: FINAL (\(Logger.summarize(trimmed)))")
                } else {
                    currentVolatile = text
                }

                lastRangeStart = result.range.start

                // Build full display text for the indicator
                let trimmedVolatile = currentVolatile.trimmingCharacters(in: .whitespaces)
                let displayText: String
                if trimmedVolatile.isEmpty {
                    displayText = finalizedText
                } else if finalizedText.isEmpty {
                    displayText = trimmedVolatile
                } else {
                    displayText = finalizedText + " " + trimmedVolatile
                }

                await MainActor.run {
                    self?.liveText = displayText
                }
            }

            Logger.shared.log("DICT[\(traceID)]: results stream ended (\(resultCount) results, \(segmentCount + 1) segments)")
        }

        // Install audio tap (nonisolated to avoid MainActor crash on audio thread)
        let levelUpdater: @Sendable (Float) -> Void = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        Self.installAudioTap(
            on: inputNode,
            micFormat: micFormat,
            targetFormat: optimalFormat,
            continuation: cont,
            levelUpdater: levelUpdater
        )

        // Suspect call #2: AVAudioEngine.start() is documented as fast
        // but does sync hardware setup under the hood. On macOS 26 with
        // certain Bluetooth audio devices it has been reported to hang
        // briefly. Time it so any future wedge here is visible.
        let engineStart = Date()
        try engine.start()
        let engineMs = Int(Date().timeIntervalSince(engineStart) * 1000)
        Logger.shared.log("DICT[\(traceID)]: AVAudioEngine.start (\(engineMs)ms)")

        // Subscribe to configuration-change notifications BEFORE marking
        // isRecording=true. Mid-recording device disconnect (Bluetooth
        // headphones, USB mic) is a known macOS 26 silent-fail mode —
        // engine continues but buffers are empty. We abort + log so the
        // failure shows up instead of producing a mysterious empty
        // transcript. Observer is per-recording (registered here, removed
        // in stop/cleanup) so we don't accumulate stale subscriptions.
        // Observer block intentionally @Sendable + nonisolated dispatch
        // back to MainActor — the notification fires from AVFoundation's
        // own queue, same isolation pattern as the TCC fix.
        let abortTraceID = traceID
        audioConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                Logger.shared.log("DICT[\(abortTraceID)]: audio configuration changed (device unplugged?) — aborting")
                self.cleanup()
                self.onAudioConfigAbort?()
            }
        }

        isRecording = true
        recordingSetupComplete = true

        let setupMs = Int(Date().timeIntervalSince(startTime) * 1000)
        Logger.shared.log("DICT[\(traceID)]: LIVE (total setup \(setupMs)ms)")
    }

    // MARK: - Stop & Return Text

    public func stopRecording() async -> String? {
        let traceID = currentTraceID ?? "unknown"

        // Wait for setup to complete if it hasn't yet
        if !recordingSetupComplete {
            Logger.shared.log("DICT[\(traceID)]: stopRecording waiting for setup to complete...")
            // Brief wait for setup — up to 500ms
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(10))
                if recordingSetupComplete { break }
            }
            if !recordingSetupComplete {
                Logger.shared.log("DICT[\(traceID)]: stopRecording setup didn't complete in 500ms, aborting")
                cleanup()
                return nil
            }
        }

        guard isRecording else {
            Logger.shared.log("DICT[\(traceID)]: stopRecording not recording")
            return nil
        }

        let stopTime = Date()
        let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0

        // Stop audio engine (no more new audio) but keep analyzer running briefly
        // so it can process any remaining buffered audio
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        Logger.shared.log("DICT[\(traceID)]: audio stopped, waiting for engine to catch up...")

        // Wait for the analyzer to finish buffered audio — but bail out as
        // soon as the text stabilises. The prior implementation captured
        // `textBefore` once before the loop and broke the moment text
        // differed from it, which meant after a single change we'd wait
        // the full 800ms. Now we update the baseline each tick and break
        // as soon as we see two consecutive identical samples (~100ms).
        var prior = liveText
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(50))
            let current = liveText
            if !current.isEmpty && current == prior {
                break
            }
            prior = current
        }

        // Now grab the final text
        let finalText = liveText.isEmpty ? nil : liveText
        Logger.shared.log("DICT[\(traceID)]: grabbed liveText (\(finalText?.count ?? 0) chars)")
        if AppSettings.shared.debugTranscripts, let finalText {
            Logger.shared.logContent("DEBUG raw", finalText)
        }

        // Clean up remaining resources
        if let observer = audioConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            audioConfigObserver = nil
        }
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        currentTranscriber = nil
        analyzer = nil
        isRecording = false
        recordingSetupComplete = false
        audioLevel = 0
        currentTraceID = nil

        let totalMs = Int(Date().timeIntervalSince(stopTime) * 1000)
        let summary = finalText.map { Logger.summarize($0) } ?? "empty"
        Logger.shared.log("DICT[\(traceID)]: stopRecording done in \(totalMs)ms (\(String(format: "%.1f", duration))s audio, \(summary))")

        return finalText
    }

    private func cleanup() {
        if let observer = audioConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            audioConfigObserver = nil
        }

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        continuation?.finish()
        continuation = nil

        resultsTask?.cancel()
        resultsTask = nil
        currentTranscriber = nil
        analyzer = nil

        isRecording = false
        recordingSetupComplete = false
        audioLevel = 0
        currentTraceID = nil
    }

    // MARK: - Audio Tap (nonisolated — runs on audio thread)

    nonisolated private static func installAudioTap(
        on inputNode: AVAudioInputNode,
        micFormat: AVAudioFormat,
        targetFormat: AVAudioFormat?,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        levelUpdater: @escaping @Sendable (Float) -> Void
    ) {
        // Buffer-flow counter — logs every 50 callbacks so we can distinguish
        // "analyzer is silent because no audio reached it" from "audio
        // reached it but Speech framework produced no results". Fires from
        // the audio thread, nonisolated — Logger is thread-safe.
        nonisolated(unsafe) var bufferCount = 0
        let bumpCount: @Sendable () -> Void = {
            bufferCount += 1
            if bufferCount == 1 {
                Logger.shared.log("audio tap: first buffer (stream live)")
            } else if bufferCount.isMultiple(of: 50) {
                Logger.shared.log("audio tap: \(bufferCount) buffers delivered")
            }
        }

        if let targetFormat, targetFormat != micFormat {
            let converter = AVAudioConverter(from: micFormat, to: targetFormat)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
                guard let converter else { return }
                let ratio = targetFormat.sampleRate / micFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil {
                    continuation.yield(AnalyzerInput(buffer: converted))
                    bumpCount()
                } else {
                    Logger.shared.log("audio tap: convert error \(error?.localizedDescription ?? "unknown")")
                }
                levelUpdater(calculateLevel(buffer))
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
                continuation.yield(AnalyzerInput(buffer: buffer))
                bumpCount()
                levelUpdater(calculateLevel(buffer))
            }
        }
    }

    // MARK: - Permission Helpers (nonisolated — avoids MainActor callback crash)

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Audio Level (nonisolated — runs on audio thread)

    nonisolated private static func calculateLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        // Accelerate's mean-of-abs is SIMD — roughly 10× faster than the
        // scalar abs+sum loop, matters because this runs on the audio
        // thread per-buffer at ~12Hz at 48kHz.
        var mean: Float = 0
        vDSP_meamgv(data, 1, &mean, vDSP_Length(count))
        return min(mean * 10, 1.0)
    }
}
