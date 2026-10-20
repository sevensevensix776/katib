import Foundation
import AppKit
import ApplicationServices
import KatibCore

// Force casts in this file are all after `CFGetTypeID(x) == AXUIElementGetTypeID()`
// or similar AX typeID guards — the canonical pattern for converting CFTypeRef
// to AXUIElement / AXValue. Suppress the lint rule for the whole file rather
// than peppering per-line disables.
// swiftlint:disable force_cast

/// Reads + writes the frontmost window via the macOS Accessibility API.
///
/// AX coordinate system: screen-space points, origin at **top-left** of the
/// primary display, y grows downward. NSScreen uses origin at bottom-left —
/// all conversions happen here.
///
/// Multi-display: we use `NSScreen` to enumerate displays and find the one
/// the window "belongs to" (largest intersection). Bundle-ID quirks list is
/// open-ended; seeded with a few we've already seen and loaded from
/// `window-quirks.json` in KatibCore at launch if present.
@MainActor
public final class WindowManager {
    public static let shared = WindowManager()

    /// Per-window frame history (by AX pid+title hash) — used by `.restore`.
    /// Survives for one session; not persisted.
    private var frameHistory: [String: CGRect] = [:]
    private let historyCap = 200

    // PIDs we've already kicked, keyed to the target process's launchDate.
    // Two reasons the kick is cached:
    //   1. `AXManualAccessibility` is idempotent but a cross-process AX
    //      write still costs ~1-5ms; skip on every subsequent hotkey.
    //   2. The 40ms RunLoop sleep that lets Chromium build its AX tree
    //      after the first kick shouldn't fire on every press.
    //
    // We key on `launchDate` (not just pid) because macOS recycles PIDs.
    // A stale entry from a quit-and-relaunched app with the same pid
    // would skip the kick on the new process — the new process has a
    // fresh AX state and genuinely needs the kick. launchDate mismatch
    // flags the reuse and forces a re-kick.
    //
    // If kAXFocusedWindow still fails after a cache-hit kick, we treat
    // the cache as stale, re-kick, and retry once. Covers apps that
    // tear down their AX tree mid-session.
    private var axKickedPIDs: [pid_t: Date] = [:]
    private var lastAXStatus: [String: String] = [:]
    /// Bundle-ID by PID. Looked up once per process via
    /// NSRunningApplication.bundleIdentifier; Info.plist read + Launch
    /// Services dict lookup is ~0.5-2ms, done on every perform() log line
    /// without this cache. Cleared by `NSWorkspace.didTerminateApplicationNotification`
    /// subscriber in the init so dead PIDs evict.
    private var bundleIDCache: [pid_t: String] = [:]

    /// Known Chromium-family bundle IDs. No longer gates the AX kick — kept
    /// purely so logs can flag "this was a Chromium app" for diagnosis.
    public nonisolated static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "app.zen-browser.zen"
    ]

    /// Pure categorizer for logging. Returns true for known Chromium browsers.
    /// Does NOT drive behavior — `enableAXIfNeeded` fires unconditionally.
    public nonisolated static func isChromiumBundle(_ bundleID: String) -> Bool {
        chromiumBundleIDs.contains(bundleID)
    }

    /// Windows currently marked as snapped. Value is the PRE-snap frame, so
    /// drag-to-unsnap can restore shape + size when the user picks up the
    /// window via its title bar.
    private var snappedWindows: [String: CGRect] = [:]

    private init() {
        // Evict caches when apps terminate — otherwise axKickedPIDs /
        // lastAXStatus / bundleIDCache / snappedWindows grow unbounded
        // as the user launches & quits apps over a session.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                return
            }
            Task { @MainActor in self?.evictPID(pid) }
        }
    }

    private func evictPID(_ pid: pid_t) {
        axKickedPIDs.removeValue(forKey: pid)
        lastAXStatus.removeValue(forKey: "\(pid)")
        bundleIDCache.removeValue(forKey: pid)
    }

    /// Returns true if a cached AX kick for `pid` is still valid — i.e. the
    /// process behind `pid` is the same one we originally kicked (same
    /// launchDate), not a macOS-recycled pid that belongs to a new process.
    ///
    /// `currentLaunchDate == nil` means the runtime lookup failed (flaky
    /// NSRunningApplication response for some short-lived helpers, sandbox
    /// edge cases). Conservative fallback: trust the cache. If the process
    /// is actually dead, the subsequent focused-window read will fail and
    /// the retry-once path re-kicks.
    public nonisolated static func isCachedKickValid(
        cachedLaunchDate: Date?,
        currentLaunchDate: Date?
    ) -> Bool {
        guard let cached = cachedLaunchDate else { return false }
        guard let current = currentLaunchDate else { return true }
        // launchDate is sampled from the kernel's process-start time at
        // NSRunningApplication init and doesn't re-measure on subsequent
        // reads of the same process — it shouldn't drift. The tolerance
        // only absorbs NSDate float-rounding; keep it tight enough that a
        // fast quit-and-relaunch (helpers, crash-respawn watchdogs) can't
        // land inside the window and skip the kick on the fresh process.
        return abs(cached.timeIntervalSince(current)) < 0.05
    }

    /// Returns the `Date` we should write into `axKickedPIDs` after a
    /// first-encounter kick, or `nil` to skip the cache write entirely.
    ///
    /// Skipping (returning nil) is correct behavior, not a failure — it
    /// just means the next press will re-run the kick. We skip when
    /// either (a) the kick itself returned a non-`.success` status for
    /// any attribute, or (b) we couldn't read the app's launchDate, so
    /// we'd have no valid reference point to compare against on the next
    /// press. Writing `Date()` in the latter case would poison the cache
    /// — on the next press we'd compare "now at write-time" to the real
    /// launchDate (possibly hours earlier), mismatch, and re-kick every
    /// press forever while believing we were caching.
    public nonisolated static func launchDateToCache(
        kickSucceeded: Bool,
        currentLaunchDate: Date?
    ) -> Date? {
        guard kickSucceeded, let launchDate = currentLaunchDate else { return nil }
        return launchDate
    }

    /// Bundle-ID lookup, memoized. First call per PID does
    /// NSRunningApplication lookup; subsequent calls are dict reads.
    private func cachedBundleID(for element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        if let cached = bundleIDCache[pid] { return cached }
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return nil
        }
        bundleIDCache[pid] = bundle
        return bundle
    }

    // MARK: - Public API

    /// Apply the action to the currently focused window. Returns false if no
    /// AX window is accessible (no Accessibility permission, no focused app,
    /// or an app that refuses AX).
    @discardableResult
    public func perform(_ action: WindowAction) -> Bool {
        guard let element = focusedWindowElement() else {
            Logger.shared.log("WindowManager: no focused window accessible")
            return false
        }

        let current = frame(of: element) ?? .zero
        let screen = screenContaining(current) ?? primaryScreen()
        guard let screen else {
            Logger.shared.log("WindowManager: no containing screen for frame=\(current)")
            return false
        }

        // Stuck Dock (macOS 27): the window server would clamp the snap short
        // of the bottom. Restart the Dock and redo the snap once it is back.
        if DockHealth.healIfStuck(screen) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.perform(action)
            }
            return true
        }

        let visible = axVisibleFrame(of: screen)

        // Display-switch actions route to another screen first.
        if action == .nextDisplay || action == .previousDisplay {
            return moveToNeighborDisplay(
                element: element,
                currentFrame: current,
                from: screen,
                forward: action == .nextDisplay
            )
        }

        guard let target = action.targetFrame(visibleFrame: visible, currentFrame: current) else {
            Logger.shared.log("WindowManager: \(action.rawValue) targetFrame returned nil")
            return false
        }

        // Log every window-op so "this hotkey did nothing" isn't opaque.
        // One line with BEFORE frame, TARGET we intend, and the window
        // owner. Diagnostic read-backs (title lookup, post-setFrame
        // re-read) gated behind `debugTranscripts` — each extra AX read
        // is a cross-process round-trip (~1-5ms) and the user doesn't
        // need them in the happy path.
        let ownerBundle = cachedBundleID(for: element) ?? "<unknown>"
        let verbose = AppSettings.shared.debugTranscripts
        if verbose {
            let ownerTitle = (copyAttribute(element, kAXTitleAttribute as String) as String?) ?? ""
            Logger.shared.log(
                "WindowManager.perform action=\(action.rawValue) owner=\(ownerBundle) " +
                "title=\"\(ownerTitle)\" screen=\(screen.frame) visible=\(visible) " +
                "before=\(current) target=\(target)"
            )
        } else {
            Logger.shared.log(
                "WindowManager.perform action=\(action.rawValue) owner=\(ownerBundle) target=\(target)"
            )
        }

        // Remember prior position so `.restore` and undo have something to undo to.
        rememberFrame(current, for: element)

        setFrame(target, on: element)

        guard verbose else {
            if Self.isSnapAction(action) {
                snappedWindows[historyKey(element)] = current
            } else {
                snappedWindows.removeValue(forKey: historyKey(element))
            }
            return true
        }

        // Read-back (verbose only): what does AX say the window's frame
        // is now? If this doesn't match `target`, the app rejected or
        // clamped our resize (iTerm2, Chrome under VoiceOver, etc.).
        let after = frame(of: element) ?? .zero
        let matches = abs(after.origin.x - target.origin.x) < 2 &&
                      abs(after.origin.y - target.origin.y) < 2 &&
                      abs(after.width - target.width) < 2 &&
                      abs(after.height - target.height) < 2
        if matches {
            Logger.shared.log("WindowManager.perform → after=\(after) ✓")
        } else {
            Logger.shared.log(
                "WindowManager.perform → after=\(after) ✗ target=\(target) — " +
                "app rejected/clamped the resize. Owner may enforce a grid or minimum size."
            )
        }
        // Mark as snapped if the action produced a distinct frame (skip resize
        // actions that only nudge the current frame — they're not snaps).
        if Self.isSnapAction(action) {
            snappedWindows[historyKey(element)] = current
        } else {
            snappedWindows.removeValue(forKey: historyKey(element))
        }
        return true
    }

    /// If the given element is marked as snapped, restore its pre-snap frame
    /// repositioned so the cursor stays on the title bar, and clear the snap
    /// state. Returns `true` if the window was unsnapped.
    ///
    /// Called by DragSnapController on mouseDown so picking up a snapped
    /// window by its title bar unsticks it — matching the Rectangle / Magnet
    /// / BetterSnapTool convention.
    @discardableResult
    public func unsnapIfNeeded(element: AXUIElement, cursor: CGPoint) -> Bool {
        let key = historyKey(element)
        guard let original = snappedWindows[key] else { return false }
        snappedWindows.removeValue(forKey: key)

        // Position the restored frame so the cursor lands at the same
        // fractional X within the title bar as it currently sits.
        let current = frame(of: element) ?? original
        let relativeX = current.width > 0
            ? (cursor.x - current.minX) / current.width
            : 0.5
        let restoredX = cursor.x - original.width * relativeX
        let repositioned = CGRect(
            x: restoredX,
            y: cursor.y - 10, // small pad below cursor so the title bar stays under it
            width: original.width,
            height: original.height
        )
        setFrame(repositioned, on: element)
        Logger.shared.log("Drag-to-unsnap: restored window to \(Int(original.width))×\(Int(original.height))")
        return true
    }

    /// Snap actions produce a frame distinct from the current one. Resize
    /// actions (larger/smaller) and display moves don't count as "snapped"
    /// for unsnap purposes — dragging after them shouldn't restore.
    static func isSnapAction(_ action: WindowAction) -> Bool {
        switch action {
        case .larger, .smaller, .restore, .nextDisplay, .previousDisplay, .center:
            return false
        case .maximize, .almostMaximize,
             .leftHalf, .rightHalf, .topHalf, .bottomHalf,
             .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            return true
        }
    }

    // MARK: - AX helpers

    /// Decode a raw `AXError` code to its SDK symbol. Raw numeric codes in
    /// logs force every future debugger to look them up; this is cheap.
    public nonisolated static func axErrorName(_ raw: Int32) -> String {
        switch raw {
        case 0:      return "success"
        case -25200: return "failure"
        case -25201: return "illegalArgument"
        case -25202: return "invalidUIElement"
        case -25203: return "invalidUIElementObserver"
        case -25204: return "cannotComplete"
        case -25205: return "attributeUnsupported"
        case -25206: return "actionUnsupported"
        case -25207: return "notificationUnsupported"
        case -25208: return "notImplemented"
        case -25209: return "notificationAlreadyRegistered"
        case -25210: return "notificationNotRegistered"
        case -25211: return "apiDisabled"
        case -25212: return "noValue"
        case -25213: return "parameterizedAttributeUnsupported"
        case -25214: return "notEnoughPrecision"
        default:     return "unknown(\(raw))"
        }
    }

    /// Copy attribute value as the expected type; nil on failure.
    private func copyAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success else { return nil }
        return raw as? T
    }

    private func focusedWindowElement() -> AXUIElement? {
        // Primary path: take the frontmost app from NSWorkspace and
        // synthesize the per-app AX element from its pid. We do NOT query
        // kAXFocusedApplicationAttribute on the system-wide element —
        // it's been documented as intermittent for over a decade
        // (rdar://10969414) and is the path Slack/Electron specifically
        // returns `noValue` on. Rectangle, AeroSpace, yabai, Hammerspoon
        // all do it this way: pid-first, never query system-wide.
        //
        // Tradeoff: NSWorkspace.frontmostApplication can lag the AX
        // server's notion of focus by ~one event-loop tick during an app
        // switch. In practice this is invisible — the AX server lags
        // BACK at least as often, and a one-frame stale read of the
        // frontmost app on a hotkey press is identical to the user
        // having pressed the hotkey one frame earlier. The race the
        // system-wide path opens (focused-app returns noValue while
        // NSWorkspace already updated) is far worse: snap silently
        // fails.
        guard let runningApp = NSWorkspace.shared.frontmostApplication else {
            // Login window, screen lock, or no GUI app frontmost — no
            // window to snap.
            Logger.shared.log("WindowManager: no NSWorkspace frontmostApplication (login/lock/no GUI app?)")
            return nil
        }
        let pid = runningApp.processIdentifier
        let app = AXUIElementCreateApplication(pid)

        // First encounter with this pid (or pid reused by a different
        // process): kick AXManualAccessibility so Chromium-family apps
        // build their AX tree. We do NOT touch AXEnhancedUserInterface —
        // writing true leaves Chrome in "VoiceOver is active" mode, which
        // makes it resize windows back to a canonical size on tab switch.
        // The temporary toggle inside `setFrame` handles any pre-existing
        // true value from a real VoiceOver session.
        let currentLaunchDate = NSRunningApplication(processIdentifier: pid)?.launchDate
        if !Self.isCachedKickValid(
            cachedLaunchDate: axKickedPIDs[pid],
            currentLaunchDate: currentLaunchDate
        ) {
            let kickSucceeded = enableAccessibilityAttributes(for: app)
            // Only cache when the kick landed AND we have a real launchDate
            // to compare against later. A failed kick that we cached would
            // be invisible on every subsequent press; a `Date()`-at-write
            // fallback would thrash the cache when the real launchDate
            // reads non-nil on the next press. See `launchDateToCache`.
            if let toCache = Self.launchDateToCache(
                kickSucceeded: kickSucceeded,
                currentLaunchDate: currentLaunchDate
            ) {
                axKickedPIDs[pid] = toCache
            }
            // Give Chromium a frame to build its AX tree before we query.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.04))
        }

        if let win = readFocusedWindow(app) { return win }

        // Cached kick wasn't enough (app's AX tree got torn down, or the
        // app just launched). Re-kick + retry once.
        enableAccessibilityAttributes(for: app)
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.04))
        if let win = readFocusedWindow(app) { return win }

        // Both reads failed — log which app refused us so the user can
        // tell whether it's an Electron flake, a corner-case window, or
        // a TCC-style permission glitch we're misdiagnosing.
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "<unknown>"
        Logger.shared.log(
            "WindowManager: kAXFocusedWindow returned nil for \(bundleID) pid=\(pid) " +
            "after kick + retry"
        )
        return nil
    }

    private func readFocusedWindow(_ app: AXUIElement) -> AXUIElement? {
        var focusedWin: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWin) == .success,
              let focusedWin,
              CFGetTypeID(focusedWin) == AXUIElementGetTypeID() else { return nil }
        return (focusedWin as! AXUIElement)
    }

    /// Attributes we proactively write to `true` on an app's AX element the
    /// first time we see it. Public so tests can lock the list down.
    ///
    /// **`AXEnhancedUserInterface` is deliberately absent.** That attribute
    /// is VoiceOver's "screen reader is active" signal. Chromium-family
    /// apps react to it by doing extra layout work AND by reconciling
    /// windows to an internal canonical size on events like tab switches —
    /// the user-visible symptom is "I resized my Chrome window, clicked
    /// another tab, and it shrunk back." Firefox and JetBrains IDEs are
    /// likely to behave similarly. `setFrame` still toggles the flag
    /// off-and-restore for a single operation if it finds it already true
    /// (real VoiceOver user, another AX tool), which is enough; we should
    /// never be the ones who turn it on.
    public nonisolated static let attributesToKickOnFirstEncounter: [String] = [
        "AXManualAccessibility",
    ]

    /// Returns `true` iff every attribute in `attributesToKickOnFirstEncounter`
    /// was set (or already `true`). Callers cache the pid as kicked only on
    /// success — a failed kick that got cached would be invisible on every
    /// subsequent press.
    @discardableResult
    private func enableAccessibilityAttributes(for app: AXUIElement) -> Bool {
        // Read-before-write — each write to these attributes is a signal
        // the OS propagates to the target app. If the attribute's already
        // true, skip. Double-read + conditional write is cheap vs. the
        // cross-process cost of an unnecessary write.
        func setIfNotAlreadyTrue(_ key: String) -> AXError {
            var current: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, key as CFString, &current)
            if let b = current as? Bool, b { return .success }
            return AXUIElementSetAttributeValue(app, key as CFString, kCFBooleanTrue)
        }
        var statuses: [(attr: String, status: AXError)] = []
        for attr in Self.attributesToKickOnFirstEncounter {
            statuses.append((attr, setIfNotAlreadyTrue(attr)))
        }
        let allSucceeded = statuses.allSatisfy { $0.status == .success }

        // Log only on state change — otherwise a hotkey held down produces
        // dozens of duplicate log lines. Track "last status we saw per PID"
        // in a small dict so transitions (new app focused, attribute starts
        // accepting, etc.) do get logged.
        var pid: pid_t = 0
        if AXUIElementGetPid(app, &pid) == .success {
            let key = "\(pid)"
            let current = statuses.map { "\($0.attr)=\($0.status.rawValue)" }.joined(separator: " ")
            if lastAXStatus[key] != current {
                lastAXStatus[key] = current
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "<unknown>"
                let tag = Self.isChromiumBundle(bundleID) ? " [Chromium]" : ""
                let decoded = statuses
                    .map { "\($0.attr)=\(Self.axErrorName($0.status.rawValue))" }
                    .joined(separator: " ")
                Logger.shared.log(
                    "WindowManager: AX kick \(bundleID)\(tag) pid=\(pid) \(decoded)"
                )
            }
        }
        return allSucceeded
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        if let p = positionRef {
            AXValueGetValue(p as! AXValue, .cgPoint, &position)
        }
        if let s = sizeRef {
            AXValueGetValue(s as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }

    internal func setFrame(_ rect: CGRect, on element: AXUIElement) {
        // Disable AXEnhancedUserInterface on the parent app during the
        // frame set. Apps that think "VoiceOver is active" silently
        // ignore or clamp AX size writes (Chrome, Firefox, Electron,
        // JetBrains).
        //
        // Restore policy: only if VoiceOver is *actually* running. The
        // attribute is per-process state on the target app and persists
        // for that app's lifetime — older Katib builds (pre-2026-04-22)
        // and other AX clients can leave a stale `true` that would
        // otherwise get ratcheted back in here every snap, keeping
        // Chrome stuck in "reconcile to canonical size on tab switch"
        // mode forever. By gating the restore on real VoiceOver, we
        // both protect VoiceOver users and clear stale bits on the
        // first snap a user runs.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = AXUIElementCreateApplication(pid)
        var prevEnhanced: CFTypeRef?
        // Read failure is acceptable: prevEnhanced stays nil and the
        // `as? Bool ?? false` cast below treats it as not-enhanced. We
        // never write `true` and we don't restore unless VoiceOver is
        // really running, so a missing read just means we skip the
        // off-flip too. Status code intentionally discarded.
        _ = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &prevEnhanced)
        let wasEnhanced = (prevEnhanced as? Bool) ?? false
        if wasEnhanced {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        let voiceOverActive = NSWorkspace.shared.isVoiceOverEnabled
        defer {
            if wasEnhanced && voiceOverActive {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }

        // Size → position → size (Rectangle's order). The first size write
        // lets the app reshape its layout; the position write moves the
        // (now-resized) window to target origin; the second size write
        // pins the final dimensions in case the position-set triggered
        // any reflow. Reversed from the old "position → size → position".
        var sizeStatus: AXError = .success
        var size = rect.size
        if let axValue = AXValueCreate(.cgSize, &size) {
            sizeStatus = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
        }
        var posStatus: AXError = .success
        var origin = rect.origin
        if let axValue = AXValueCreate(.cgPoint, &origin) {
            posStatus = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
        }
        var size2Status: AXError = .success
        var sizeAgain = rect.size
        if let axValue = AXValueCreate(.cgSize, &sizeAgain) {
            size2Status = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
        }

        if posStatus != .success || sizeStatus != .success || size2Status != .success {
            Logger.shared.log(
                "WindowManager.setFrame AX errors: " +
                "size=\(Self.axErrorName(sizeStatus.rawValue)) " +
                "pos=\(Self.axErrorName(posStatus.rawValue)) " +
                "size2=\(Self.axErrorName(size2Status.rawValue))"
            )
        }
    }

    /// Resolve the bundle ID of the app owning an AX element, for log
    /// breadcrumbs. Chain: element → pid → NSRunningApplication → bundleID.
    private func bundleIDForElement(_ element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    // MARK: - Screen helpers (NSScreen is bottom-left; AX is top-left)

    /// Convert the screen's snap frame (visibleFrame minus an auto-hidden Dock;
    /// bottom-left origin) to AX top-left coordinates.
    private func axVisibleFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = primaryScreen()?.frame.height ?? screen.frame.height
        let vf = screen.snapFrame
        let axY = primaryHeight - vf.maxY
        return CGRect(x: vf.origin.x, y: axY, width: vf.width, height: vf.height)
    }

    private func screenContaining(_ axFrame: CGRect) -> NSScreen? {
        let primaryHeight = primaryScreen()?.frame.height ?? 0
        // Convert AX frame (top-left) back to NSScreen space (bottom-left).
        let nsFrame = CGRect(
            x: axFrame.origin.x,
            y: primaryHeight - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        // Pick the screen whose frame has the largest intersection area.
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(nsFrame)
            let area = inter.width * inter.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        return best?.screen ?? NSScreen.main
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first
    }

    // MARK: - Multi-display

    private func moveToNeighborDisplay(
        element: AXUIElement,
        currentFrame: CGRect,
        from current: NSScreen,
        forward: Bool
    ) -> Bool {
        let screens = NSScreen.screens
        guard screens.count > 1,
              let currentIdx = screens.firstIndex(of: current) else { return false }
        let nextIdx = forward
            ? (currentIdx + 1) % screens.count
            : (currentIdx - 1 + screens.count) % screens.count
        let target = screens[nextIdx]

        let srcVisible = axVisibleFrame(of: current)
        let dstVisible = axVisibleFrame(of: target)

        // Preserve relative position + proportional size when changing displays.
        let relX = (currentFrame.minX - srcVisible.minX) / srcVisible.width
        let relY = (currentFrame.minY - srcVisible.minY) / srcVisible.height
        let relW = currentFrame.width / srcVisible.width
        let relH = currentFrame.height / srcVisible.height

        let newFrame = CGRect(
            x: dstVisible.minX + relX * dstVisible.width,
            y: dstVisible.minY + relY * dstVisible.height,
            width: relW * dstVisible.width,
            height: relH * dstVisible.height
        )
        rememberFrame(currentFrame, for: element)
        setFrame(newFrame, on: element)
        return true
    }

    // MARK: - History (for .restore)

    internal func rememberFrame(_ rect: CGRect, for element: AXUIElement) {
        let key = historyKey(element)
        frameHistory[key] = rect
        if frameHistory.count > historyCap {
            frameHistory.removeValue(forKey: frameHistory.keys.randomElement() ?? "")
        }
    }

    internal func markSnapped(_ element: AXUIElement, preSnap: CGRect) {
        snappedWindows[historyKey(element)] = preSnap
    }

    internal func clearSnapMark(for element: AXUIElement) {
        snappedWindows.removeValue(forKey: historyKey(element))
    }

    internal func historyKey(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let title: String? = copyAttribute(element, kAXTitleAttribute)
        return "\(pid)::\(title ?? "_")"
    }
}
