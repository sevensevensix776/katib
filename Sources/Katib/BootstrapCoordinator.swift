import AppKit
import AVFoundation
import Foundation
import Speech
import KatibCore

/// Single-source-of-truth for "is Katib ready to do dangerous work."
///
/// Why this exists: pre-2026-04-29 launch ran `transcriber.setup()`,
/// installed all hotkey consumers, and registered the welcome popover
/// unconditionally — even when Accessibility was missing. The CGEventTap
/// would fail to install (×6 retries logged), listeners would queue up
/// in data structures with no live tap, and when the user later granted
/// AX live, all pending registrations went live simultaneously against
/// an audio-engine + transcriber pipeline that had been set up under
/// the no-AX world. That mismatched-init-context state caused at least
/// one global keyboard lockup (2026-04-29 ~15:58).
///
/// This coordinator gates all of that behind a single state machine.
/// Bootstrap runs ONCE, atomically, only when all three permissions
/// (mic / speech / accessibility) are granted. If any permission is
/// revoked while running, we tear down cleanly back to `waiting`.
///
/// State diagram:
///
///   waiting ──(all granted)──→ bootstrapping ──(bootstrap done)──→ bootstrapped
///      ↑                              │                                  │
///      │                              ↓                                  │
///      └──(any revoked)─────────── (cancelled) ←──(any revoked)─────────┘
///
/// All transitions log a `BOOT[<traceID>]:` line so a forensic trail
/// exists for every bootstrap/teardown cycle.
@MainActor
final class BootstrapCoordinator {
    static let shared = BootstrapCoordinator()

    private(set) var state: BootstrapState = .waiting
    private(set) var lastSnapshot: PermissionSnapshot = .denied

    private var pollTimer: Timer?
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrap: (@MainActor (String) async -> Void)?
    private var teardown: (@MainActor (String) -> Void)?

    /// Wire bootstrap + teardown closures and start polling. Call once
    /// from `applicationDidFinishLaunching` after the menu bar + welcome
    /// popover are wired (those don't need permissions to be safe).
    ///
    /// - Parameters:
    ///   - bootstrap: Runs the heavy startup — `transcriber.setup`,
    ///     hotkey installs, command palette, etc. Receives a trace ID
    ///     to stamp into logs so the bootstrap's lifecycle is grep-able.
    ///   - teardown: Reverses bootstrap. Stops the audio engine, kills
    ///     hotkey listeners, hides the live indicator. Should NOT
    ///     destroy user data (clipboard etc. stays loaded).
    func start(
        bootstrap: @escaping @MainActor (String) async -> Void,
        teardown: @escaping @MainActor (String) -> Void
    ) {
        self.bootstrap = bootstrap
        self.teardown = teardown

        let snap = PermissionSnapshot.current()
        lastSnapshot = snap
        Logger.shared.log("BOOT: coordinator started \(snap.summary)")

        evaluate()
        startPolling()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // 1s is a compromise: fast enough that flipping a permission in
        // System Settings feels responsive, slow enough that the polling
        // doesn't show up in any profile. macOS doesn't expose proper
        // change notifications for these three permissions; polling is
        // what HotkeyManager already does for AX.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }

        // Power management. Mac sleep can trigger TCC re-validation: if
        // AX gets revoked under us, the existing CGEventTap goes into a
        // zombie state where the kernel routes keyboard events through
        // it but the callback never fires (because perm check fails at
        // delivery). Net effect is a global keyboard freeze that needs
        // a Katib relaunch to clear — exactly what bit Asif on
        // 2026-04-29 ~20:23. Subscribing here lets us react in <100ms
        // on wake instead of waiting up to 1s for the next pollTimer.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Logger.shared.log("BOOT: mac woke (state=\(self.state)) — re-evaluating + recycling tap")
                self.evaluate()
                // Belt + suspenders: recycle the tap even when perms
                // still appear granted. A tap that survived a TCC
                // revoke→restore cycle during sleep can still be in
                // the suppression-but-no-callback zombie state. A
                // fresh tapCreate either builds healthy or fails
                // cleanly and lets evaluate() pull us to .waiting.
                HotkeyTapRouter.shared.recycleTap()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Logger.shared.log("BOOT: mac sleeping (state=\(self.state) \(self.lastSnapshot.summary))")
                // Sleeping mid-recording leaves AVAudioEngine in an
                // unknown state on wake. Hold-to-talk dictation makes
                // this hard to trigger in practice (sleep is initiated
                // by UI), but the cost of a defensive abort is one log
                // line and a discarded transcript fragment. Cheaper
                // than debugging audio-state corruption later.
                self.willSleep?()
            }
        }

        // User fast-switching (login window, "Switch User") can trigger
        // TCC revalidation on the returning user. Same fix shape as
        // didWake: recycle the tap proactively because we don't know
        // if our AX perm survived the user-switch round-trip.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Logger.shared.log("BOOT: session became active — re-evaluating + recycling tap")
                self.evaluate()
                HotkeyTapRouter.shared.recycleTap()
            }
        }
    }

    /// Called from the willSleep observer. AppDelegate sets this to
    /// `transcriber.abortRecording` so audio capture is torn down before
    /// the kernel suspends us, instead of letting AVAudioEngine slot into
    /// an undefined post-wake state.
    var willSleep: (@MainActor () -> Void)?

    /// Recompute permissions and decide whether to advance/retreat. Idempotent
    /// — calling repeatedly with no change does nothing. Safe to spam.
    func evaluate() {
        let snap = PermissionSnapshot.current()
        let changed = snap != lastSnapshot
        if changed {
            Logger.shared.log("BOOT: permissions changed \(lastSnapshot.summary) → \(snap.summary)")
            lastSnapshot = snap
        }

        switch bootstrapAction(from: state, snapshot: snap) {
        case .advance:
            advanceToBootstrapping()

        case .retreat(let reason):
            retreatToWaiting(reason: reason)

        case .cancel(let reason):
            // Permission flipped off mid-bootstrap. Cancel the in-flight
            // task; the bootstrap closure should respect Task.isCancelled
            // at suspension points, but even if it ignores cancellation
            // we'll just complete and then evaluate() will fire again
            // and pull us back to waiting.
            Logger.shared.log("BOOT: \(reason) — cancelling")
            bootstrapTask?.cancel()
            bootstrapTask = nil
            transition(to: .waiting, traceID: TraceID.new())

        case .noop:
            break
        }
    }

    private func advanceToBootstrapping() {
        let traceID = TraceID.new()
        transition(to: .bootstrapping, traceID: traceID)

        bootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let start = Date()
            Logger.shared.log("BOOT[\(traceID)]: bootstrap begin \(self.lastSnapshot.summary)")
            await self.bootstrap?(traceID)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

            // Bootstrap may have taken seconds; in that window a
            // permission could have been revoked. If so, evaluate()
            // already saw it and pulled us back to .waiting — don't
            // override that here.
            guard self.state == .bootstrapping else {
                Logger.shared.log("BOOT[\(traceID)]: bootstrap completed (\(elapsedMs)ms) but state is \(self.state) — skipping advance")
                return
            }
            self.transition(to: .bootstrapped, traceID: traceID)
            Logger.shared.log("BOOT[\(traceID)]: bootstrap done (\(elapsedMs)ms) — Katib ready")
            self.bootstrapTask = nil
        }
    }

    private func retreatToWaiting(reason: String) {
        let traceID = TraceID.new()
        Logger.shared.log("BOOT[\(traceID)]: tearing down — \(reason)")
        transition(to: .waiting, traceID: traceID)
        teardown?(traceID)
    }

    private func transition(to new: BootstrapState, traceID: String) {
        Logger.shared.log("BOOT[\(traceID)]: \(state) → \(new)")
        state = new
    }
}

// MARK: - OS-coupled snapshot reader

extension PermissionSnapshot {
    /// Reads the current OS permission state. Same APIs PopoverState
    /// and SettingsView already use, kept in one place so the
    /// coordinator's decision can never drift from what the UI shows.
    static func current() -> PermissionSnapshot {
        PermissionSnapshot(
            mic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speech: SFSpeechRecognizer.authorizationStatus() == .authorized,
            accessibility: AXIsProcessTrusted()
        )
    }
}

// PermissionSnapshot value type + state transition decision live in
// KatibCore so they can be tested without touching the OS.
