import Foundation
import Cocoa
import Carbon.HIToolbox
import KatibCore

/// Global hotkey detection — Option key hold-to-talk. Migrated to use
/// the shared `HotkeyTapRouter` for modifier (flagsChanged) + keyDown
/// observation; previously owned its own CGEventTap, which was the last
/// feature holdout after the v1.28 unification.
@MainActor
public final class HotkeyManager: ObservableObject {
    public static let shared = HotkeyManager()

    @Published public var isHotkeyPressed = false
    @Published public var hasAccessibilityPermission = false

    /// Hold long enough (>minHoldDuration) → recording started, fires onHotkeyUp on release.
    public var onHotkeyDown: (() -> Void)?
    public var onHotkeyUp: (() -> Void)?
    /// Quick double-tap → re-paste last transcription.
    public var onDoubleTap: (() -> Void)?
    /// User pressed Esc mid-recording → abort without pasting.
    public var onAbort: (() -> Void)?

    /// Router registrations. Nil until `startListening()` succeeds;
    /// cleared on stop. Keeping both separately lets us hot-swap one
    /// without the other.
    private var modifierToken: HotkeyTapRouter.ModifierObserverToken?
    private var keyListenerToken: HotkeyTapRouter.Token?
    private var accessibilityPollTimer: Timer?

    /// Active hotkey's keycode, read from AppSettings. Now on MainActor
    /// everywhere since the router's handlers arrive on MainActor —
    /// replaces the old lock-protected nonisolated snapshot.
    private var currentKeyCode: Int64 {
        Int64(AppSettings.shared.hotkeySide.keyCode)
    }

    // Solo-press tracking
    private var optionDownClean = false
    private var recordingTriggered = false

    // Minimum hold duration (prevents accidental taps). Matches muesli's
    // startDelay so the perceived "is it recording yet" lag feels the same.
    private let minHoldDuration: TimeInterval = 0.25
    private var keyDownTime: Date?
    private var holdTimer: Timer?

    // Double-tap detection
    private let doubleTapWindow: TimeInterval = 0.4
    private var lastTapTime: Date?

    private init() {
        checkAccessibilityPermission()
        NotificationCenter.default.addObserver(
            forName: .katibHotkeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Logger.shared.log("Hotkey changed → \(AppSettings.shared.hotkeySide.displayName)")
            }
        }
    }

    public func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    nonisolated public func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Task { @MainActor in
            self.startAccessibilityPoll()
        }
    }

    /// Poll every second until Accessibility flips on, then start listening.
    /// Stored so repeated requests don't stack multiple polling timers.
    private func startAccessibilityPoll() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            Task { @MainActor in
                guard let self else { return }
                self.hasAccessibilityPermission = true
                self.startListening()
                self.accessibilityPollTimer = nil
            }
        }
    }

    public func startListening() {
        guard hasAccessibilityPermission,
              modifierToken == nil, keyListenerToken == nil else { return }

        modifierToken = HotkeyTapRouter.shared.registerModifierObserver {
            [weak self] keyCode, flags in
            self?.handleFlagsEvent(keyCode: keyCode, flags: flags)
        }
        keyListenerToken = HotkeyTapRouter.shared.registerListener {
            [weak self] keyCode, _ in
            // Esc = abort; anything else during an active hold = combo cancel.
            if keyCode == 53 { self?.handleAbort() }
            else { self?.handleComboCancel() }
        }
        Logger.shared.log("Hotkey listener started (via HotkeyTapRouter)")
    }

    public func stopListening() {
        if let modifierToken {
            HotkeyTapRouter.shared.remove(modifierToken)
            self.modifierToken = nil
        }
        if let keyListenerToken {
            HotkeyTapRouter.shared.remove(keyListenerToken)
            self.keyListenerToken = nil
        }
    }

    /// Handle a flags-changed event from the router. Already on MainActor.
    /// The hold/double-tap/combo-cancel state machine moved verbatim from
    /// the old inline Task block inside the CGEvent callback.
    private func handleFlagsEvent(keyCode: UInt32, flags: UInt64) {
        guard Int64(keyCode) == currentKeyCode else { return }

        let optionPressed = (flags & CGEventFlags.maskAlternate.rawValue) != 0
        let hasOtherModifiers = (flags & CGEventFlags.maskCommand.rawValue) != 0
                             || (flags & CGEventFlags.maskControl.rawValue) != 0
                             || (flags & CGEventFlags.maskShift.rawValue) != 0

        if optionPressed && !isHotkeyPressed {
            // === KEY DOWN ===
            isHotkeyPressed = true
            keyDownTime = Date()
            if hasOtherModifiers {
                optionDownClean = false
                recordingTriggered = false
            } else {
                optionDownClean = true
                holdTimer?.invalidate()
                holdTimer = Timer.scheduledTimer(withTimeInterval: minHoldDuration, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.optionDownClean, self.isHotkeyPressed else { return }
                        self.recordingTriggered = true
                        Logger.shared.log("Option HELD (\(String(format: "%.0f", self.minHoldDuration * 1000))ms) → recording")
                        self.onHotkeyDown?()
                    }
                }
            }
        } else if !optionPressed && isHotkeyPressed {
            // === KEY UP ===
            isHotkeyPressed = false
            let holdDuration = keyDownTime.map { Date().timeIntervalSince($0) } ?? 0
            holdTimer?.invalidate()
            holdTimer = nil
            if recordingTriggered {
                Logger.shared.log("Option UP (\(String(format: "%.1f", holdDuration))s hold)")
                onHotkeyUp?()
            } else if optionDownClean && holdDuration < minHoldDuration {
                let now = Date()
                if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < doubleTapWindow {
                    Logger.shared.log("Double-tap → re-paste")
                    lastTapTime = nil
                    onDoubleTap?()
                } else {
                    lastTapTime = now
                }
            }
            optionDownClean = false
            recordingTriggered = false
        }
    }

    /// Called on the main actor when a non-hotkey key is pressed. If Option was
    /// previously held cleanly, treat as a combo and cancel any in-flight recording.
    private func handleComboCancel() {
        guard optionDownClean else { return }
        optionDownClean = false
        holdTimer?.invalidate()
        holdTimer = nil
        if recordingTriggered {
            Logger.shared.log("Key combo — cancelling")
            recordingTriggered = false
            onHotkeyUp?()
        }
    }

    /// Called on the main actor when Esc is pressed during an active hotkey
    /// hold. Aborts the recording without pasting.
    private func handleAbort() {
        guard isHotkeyPressed else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        if recordingTriggered {
            Logger.shared.log("Esc pressed → aborting recording")
            recordingTriggered = false
            onAbort?()
        }
        optionDownClean = false
    }
}
