import Foundation
import AppKit
import os

/// Single CGEventTap that multiplexes keyboard-shortcut handling across
/// every KatibCore-aware feature. Replaces a proliferation of independent
/// taps — each of which had to own its own timeout-recovery, install
/// logic, and modifier masking.
///
/// ## Threading
///
/// The CGEventTap runs on a **dedicated thread**, never on main. macOS
/// routes every keyboard event through every active session tap before
/// delivering to apps; if the runloop the tap is attached to wedges, the
/// kernel times out and the user's keyboard goes dark for *every* app
/// until recovery runs. Putting the tap on its own runloop makes sure a
/// stuck main thread (slow startup, beachball, deadlock during a rebuild
/// race) can't lock the keyboard out of every app on the system.
///
/// Handlers themselves are still typed `@MainActor` and are dispatched
/// back to main — so a wedged main still means the *handler* won't fire,
/// but events continue flowing to other apps. That's the key win.
///
/// ## Two registration kinds
///
/// **Consumers** match a specific `(keyCode, flagMask)` and, on hit,
/// invoke the handler + return `nil` from the tap callback so the focused
/// app doesn't also see the keystroke. Used by window hotkeys, clipboard
/// picker, screenshot triggers, etc.
///
/// **Listeners** see every keyDown and cannot consume. Used for
/// observation — keystroke debugging, text-expander trigger buffers,
/// voice-command activation sequences.
///
/// ## Consumption order
///
/// Consumers are matched first. If any consumer's binding matches, the
/// event is consumed before listeners run. This prevents a listener from
/// observing keystrokes that a global hotkey is about to act on (e.g.
/// text expander trying to interpret fn+⌃⌥⌘+Left as typing).
///
/// ## Lifecycle
///
/// The tap is installed on first registration and torn down when the last
/// registration is removed. `tapDisabledByTimeout` /
/// `tapDisabledByUserInput` are handled centrally on the tap thread —
/// each feature no longer needs its own recovery code, and recovery does
/// **not** depend on main being alive.
public final class HotkeyTapRouter: @unchecked Sendable {
    public static let shared = HotkeyTapRouter()

    public struct Token: Hashable, Sendable {
        let id: UUID
        fileprivate init() { self.id = UUID() }
    }

    /// Distinct token type so the compiler catches mismatched remove calls
    /// (you can't accidentally pass a consumer Token where a modifier
    /// observer token is expected). Runtime behaviour is identical.
    public struct ModifierObserverToken: Hashable, Sendable {
        let id: UUID
        fileprivate init() { self.id = UUID() }
    }

    private struct Consumer {
        let keyCode: UInt32
        let flagMask: UInt64
        let handler: @MainActor () -> Void
    }

    /// Guards every collection below. Held only for dict reads/writes —
    /// never across handler dispatch, so it can't deadlock with main.
    private let lock = OSAllocatedUnfairLock()
    private var consumers: [Token: Consumer] = [:]
    private var listeners: [Token: @MainActor (UInt32, UInt64) -> Void] = [:]
    /// Observers for `.flagsChanged` events — modifier key down/up
    /// transitions. Used by dictation's hold-to-talk detection.
    private var modifierObservers: [ModifierObserverToken: @MainActor (UInt32, UInt64) -> Void] = [:]

    /// Tap-thread state. Only touched on `tapRunLoop` after init().
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: CFRunLoopTimer?
    private var tapRunLoop: CFRunLoop?
    private let tapReady = DispatchSemaphore(value: 0)

    private init() {
        spawnTapThread()
        // Retry tap installation when the app returns to foreground. Covers
        // the "user just granted Accessibility in System Settings and tabbed
        // back" case — without this, the tap stays dead until Katib is
        // relaunched, which was the single most confusing failure mode we
        // shipped during v1.28 development.
        // queue:.main locks the contract — AppKit posts this on main
        // today, but past macOS releases have changed posting semantics
        // for system notifications, and we don't want a future change
        // to silently invoke this block on a non-main thread. Body
        // hops to the tap thread immediately, so main isn't held.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.runOnTapThread { self?.retryIfTapDead() }
        }
    }

    /// True iff we have consumers/listeners registered but no live tap.
    /// Used by the menu bar icon to show a "needs Accessibility" indicator.
    /// Reads tap-thread state racily on purpose — the icon is debounced by
    /// a 3s timer so a brief inconsistent read just settles next tick.
    public var isTapDead: Bool {
        let hasRegistrations = lock.withLock {
            !(consumers.isEmpty && listeners.isEmpty && modifierObservers.isEmpty)
        }
        return eventTap == nil && hasRegistrations
    }

    // MARK: - Public API

    /// Tear down the existing CGEventTap and create a fresh one. Used on
    /// wake-from-sleep: if AX permission was revoked during sleep, the
    /// existing tap is in a zombie state — it exists in the kernel but
    /// the permission check at delivery time fails, and the kernel
    /// routes keyboard events through it but never fires the callback.
    /// The 2s watchdog's `CGEvent.tapEnable` is a silent no-op against
    /// a permission-stripped tap. Result: global keyboard suppression
    /// until process restart.
    ///
    /// `tapCreate` re-checks AX at create time, so a fresh tap either
    /// builds healthy (perms still granted) or fails to create cleanly
    /// (perms revoked → BootstrapCoordinator teardown handles cleanup
    /// on its next evaluate tick).
    public func recycleTap() {
        runOnTapThread { [weak self] in
            guard let self else { return }
            let hadTap = self.eventTap != nil
            Logger.shared.log("HotkeyTapRouter: recycling tap (hadTap=\(hadTap))")
            self.uninstall()
            self.installIfNeeded()
        }
    }

    /// Register a binding. On a matching keyDown the handler fires and the
    /// event is consumed (the focused app never sees it). Returns a token
    /// — pass it to `remove(_:)` to unregister.
    @discardableResult
    public func registerConsumer(
        keyCode: UInt32,
        flagMask: UInt64,
        handler: @escaping @MainActor () -> Void
    ) -> Token {
        let token = Token()
        lock.withLock {
            consumers[token] = Consumer(keyCode: keyCode, flagMask: flagMask, handler: handler)
        }
        runOnTapThread { [weak self] in self?.installIfNeeded() }
        return token
    }

    /// Observe every keyDown. Handler receives the normalized
    /// `(keyCode, flags)` — CGEvent itself is not Sendable, so we hand off
    /// the Sendable subset most listeners actually use. Cannot consume;
    /// the event continues to the focused app.
    @discardableResult
    public func registerListener(
        _ handler: @escaping @MainActor (_ keyCode: UInt32, _ flags: UInt64) -> Void
    ) -> Token {
        let token = Token()
        lock.withLock {
            listeners[token] = handler
        }
        runOnTapThread { [weak self] in self?.installIfNeeded() }
        return token
    }

    /// Observe `.flagsChanged` events — modifier key down/up transitions.
    /// Handler receives the normalized `(keyCode, flags)` Sendable pair.
    /// Used by dictation's hold-to-talk detection and any future feature
    /// that cares about modifier state changes. Can't consume (flagsChanged
    /// always passes through to the focused app).
    @discardableResult
    public func registerModifierObserver(
        _ handler: @escaping @MainActor (_ keyCode: UInt32, _ flags: UInt64) -> Void
    ) -> ModifierObserverToken {
        let token = ModifierObserverToken()
        lock.withLock {
            modifierObservers[token] = handler
        }
        runOnTapThread { [weak self] in self?.installIfNeeded() }
        return token
    }

    public func remove(_ token: Token) {
        let nowEmpty: Bool = lock.withLock {
            consumers.removeValue(forKey: token)
            listeners.removeValue(forKey: token)
            return consumers.isEmpty && listeners.isEmpty && modifierObservers.isEmpty
        }
        if nowEmpty {
            runOnTapThread { [weak self] in self?.uninstall() }
        }
    }

    public func remove(_ token: ModifierObserverToken) {
        let nowEmpty: Bool = lock.withLock {
            modifierObservers.removeValue(forKey: token)
            return consumers.isEmpty && listeners.isEmpty && modifierObservers.isEmpty
        }
        if nowEmpty {
            runOnTapThread { [weak self] in self?.uninstall() }
        }
    }

    public func removeAllConsumers() {
        let nowEmpty: Bool = lock.withLock {
            consumers.removeAll()
            return consumers.isEmpty && listeners.isEmpty && modifierObservers.isEmpty
        }
        if nowEmpty {
            runOnTapThread { [weak self] in self?.uninstall() }
        }
    }

    /// Five-bit mask of the modifier bits we actually care about. Used by
    /// consumers that want to compare CGEventFlags without carrying stray
    /// OS bits (.maskAlphaShift / .maskNumericPad / .maskHelp / etc.).
    public nonisolated static let interestingFlags: UInt64 =
        CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    /// macOS hardware-remaps these keycodes when fn is held on a laptop —
    /// fn+Left→Home (115), fn+Right→End (119), fn+Up→PageUp (116),
    /// fn+Down→PageDown (121), fn+Delete→ForwardDelete (117). The fn bit
    /// on these events is redundant with the keycode itself, so we strip
    /// it before matching so a binding works whether the user has a real
    /// Home key or is pressing fn+Left.
    nonisolated private static let fnRemappedKeycodes: Set<UInt32> = [
        115, 116, 117, 119, 121
    ]

    /// Exposed `internal` for tests — this is the only pure-logic function
    /// in the router and it's where all our fn-remapping correctness lives.
    nonisolated static func normalizedFlags(keyCode: UInt32, rawFlags: UInt64) -> UInt64 {
        var flags = rawFlags & interestingFlags
        if fnRemappedKeycodes.contains(keyCode) {
            flags &= ~CGEventFlags.maskSecondaryFn.rawValue
        }
        return flags
    }

    /// Convert Carbon modifier bits (`cmdKey`/`shiftKey`/`optionKey`/`controlKey`
    /// from `Carbon.HIToolbox`) to a `CGEventFlags` mask suitable for
    /// `registerConsumer(flagMask:)`. Everything stored in AppSettings uses
    /// the Carbon bit format, so this is the canonical bridge.
    public nonisolated static func cgFlagMask(carbonModifiers: UInt32) -> UInt64 {
        let shiftKey: UInt32 = 0x0200
        let controlKey: UInt32 = 0x1000
        let optionKey: UInt32 = 0x0800
        let cmdKey: UInt32 = 0x0100
        var flags: UInt64 = 0
        if carbonModifiers & shiftKey != 0 { flags |= CGEventFlags.maskShift.rawValue }
        if carbonModifiers & controlKey != 0 { flags |= CGEventFlags.maskControl.rawValue }
        if carbonModifiers & optionKey != 0 { flags |= CGEventFlags.maskAlternate.rawValue }
        if carbonModifiers & cmdKey != 0 { flags |= CGEventFlags.maskCommand.rawValue }
        return flags
    }

    /// Check whether any currently-registered consumer already owns the
    /// given `(keyCode, flagMask)` pair. Callers (settings UI) use this to
    /// warn the user before writing a duplicate binding — replaces the
    /// conflict detection Carbon's `RegisterEventHotKey` did automatically.
    ///
    /// Only checks within Katib — can't tell if another *app* has claimed the
    /// same combo via its own CGEventTap (CGEventTap doesn't expose that).
    public func isBindingAvailable(keyCode: UInt32, flagMask: UInt64) -> Bool {
        lock.withLock {
            !consumers.values.contains { $0.keyCode == keyCode && $0.flagMask == flagMask }
        }
    }

    // MARK: - Tap thread

    private func spawnTapThread() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            self.tapReady.signal()

            // CFRunLoop returns immediately if it has no sources/timers. Add
            // a no-op timer way out in the future so the loop parks until we
            // post blocks to it via runOnTapThread().
            let keepalive = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 60 * 60 * 24 * 365,
                60 * 60 * 24 * 365,
                0, 0
            ) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepalive, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "katib.HotkeyTapRouter"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Wait until the thread has captured its runloop. Bounded — if the
        // thread fails to start in 1s something is very wrong; bail and let
        // tap install fail loudly later.
        _ = tapReady.wait(timeout: .now() + 1.0)
    }

    private func runOnTapThread(_ block: @escaping () -> Void) {
        guard let runloop = tapRunLoop else { return }
        CFRunLoopPerformBlock(runloop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runloop)
    }

    private func retryIfTapDead() {
        guard eventTap == nil else { return }
        let hasRegistrations = lock.withLock {
            !(consumers.isEmpty && listeners.isEmpty && modifierObservers.isEmpty)
        }
        guard hasRegistrations else { return }
        Logger.shared.log("HotkeyTapRouter: retrying tap install (app became active)")
        installIfNeeded()
    }

    // MARK: - Tap lifecycle (all called on tapRunLoop)

    private func installIfNeeded() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let me = Unmanaged<HotkeyTapRouter>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.shared.log("HotkeyTapRouter: tap creation failed")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        Logger.shared.log("HotkeyTapRouter: started")
    }

    private func uninstall() {
        stopWatchdog()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
            Logger.shared.log("HotkeyTapRouter: stopped")
        }
    }

    /// Periodic poke to re-enable the tap if macOS disabled it without the
    /// callback firing (e.g. user-input timeout in a quiet window where no
    /// new event arrives to trip the in-callback recovery). Cheap — just a
    /// `CGEventTapIsEnabled` check + a `tapEnable` if needed.
    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 2.0,
            2.0,
            0, 0
        ) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                Logger.shared.log("HotkeyTapRouter: watchdog re-enabling disabled tap")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        if let timer = watchdogTimer {
            CFRunLoopTimerInvalidate(timer)
            watchdogTimer = nil
        }
    }

    // MARK: - Tap callback (runs on tapRunLoop)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-enable directly on the tap thread. Original code hopped to
            // @MainActor here — fatal if main was the thing that wedged us.
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            let observers: [@MainActor (UInt32, UInt64) -> Void] = lock.withLock {
                modifierObservers.isEmpty ? [] : Array(modifierObservers.values)
            }
            if !observers.isEmpty {
                let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags.rawValue
                Task { @MainActor in
                    for handler in observers { handler(keyCode, flags) }
                }
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // Snapshot state under the lock — keep the critical section tight,
        // do all dispatch outside the lock.
        let (consumerSnapshot, listenerSnapshot): ([Consumer], [@MainActor (UInt32, UInt64) -> Void]) = lock.withLock {
            // Fast-path: if nobody's registered, hand back empty arrays and
            // skip allocation noise. This is the single hottest code path
            // in the app — fires on every global keyDown.
            if consumers.isEmpty && listeners.isEmpty {
                return ([], [])
            }
            return (Array(consumers.values), Array(listeners.values))
        }
        if consumerSnapshot.isEmpty && listenerSnapshot.isEmpty {
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = Self.normalizedFlags(keyCode: keyCode, rawFlags: event.flags.rawValue)

        // Consumers take priority — if any match, consume the event before
        // letting listeners see it.
        for consumer in consumerSnapshot
        where consumer.keyCode == keyCode && consumer.flagMask == flags {
            let handler = consumer.handler
            Task { @MainActor in handler() }
            return nil
        }

        // Listeners always observe; they can't consume.
        if !listenerSnapshot.isEmpty {
            Task { @MainActor in
                for handler in listenerSnapshot { handler(keyCode, flags) }
            }
        }
        return Unmanaged.passRetained(event)
    }
}
