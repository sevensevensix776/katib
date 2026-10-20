import XCTest
@testable import KatibWindow

/// Locks down the AX attribute-kick policy and the PID-reuse guard.
///
/// Both of these are impossible to test via the real Accessibility API —
/// that requires a running target app like Chrome, and the bugs they
/// prevent are invisible at build time. The tests below treat the policy
/// lists and the pure decision function as the testable surface, so a
/// regression here shows up in CI instead of after a release.
final class AXKickPolicyTests: XCTestCase {

    // MARK: - Attribute kick list

    func testKicksManualAccessibility() {
        // AXManualAccessibility is the supported way to ask Chromium-family
        // apps to build their AX tree. Without it, kAXFocusedWindow returns
        // nothing on Chrome/Edge/Brave/Arc and window-snap silently does
        // nothing.
        XCTAssertTrue(
            WindowManager.attributesToKickOnFirstEncounter.contains("AXManualAccessibility"),
            "AXManualAccessibility must be in the kick list — without it, Chrome's AX tree never builds"
        )
    }

    func testDoesNotForceEnhancedUserInterface() {
        // Tripwire for the Chrome tab-shrink bug: writing
        // AXEnhancedUserInterface=true leaves Chrome in "VoiceOver is
        // active" mode, which makes it reconcile windows back to a
        // canonical size whenever layout events fire (notably tab
        // switches). Firefox and JetBrains IDEs exhibit similar behavior.
        //
        // If you're tempted to add "AXEnhancedUserInterface" here:
        // don't. `setFrame` already toggles it off-and-restore for a
        // single operation when it finds the flag already set by a real
        // VoiceOver session or another AX tool. Katib should never be
        // the source of the write.
        XCTAssertFalse(
            WindowManager.attributesToKickOnFirstEncounter.contains("AXEnhancedUserInterface"),
            "AXEnhancedUserInterface must NOT be in the kick list — causes Chrome window-shrink on tab switch"
        )
    }

    func testKickListIsMinimal() {
        // Every attribute here is a persistent side-effect on a
        // third-party process that we never restore. Keep the list as
        // small as the feature allows. If this count needs to grow,
        // document why in the attribute's comment above the list.
        XCTAssertEqual(
            WindowManager.attributesToKickOnFirstEncounter.count,
            1,
            "Kick list grew — each entry is a persistent write on a third-party app; justify in comments"
        )
    }

    // MARK: - PID-reuse guard

    func testCacheInvalidWhenNeverKicked() {
        XCTAssertFalse(
            WindowManager.isCachedKickValid(cachedLaunchDate: nil, currentLaunchDate: Date()),
            "nil cache means never kicked — must force a kick"
        )
    }

    func testCacheValidWhenLaunchDatesMatch() {
        let date = Date(timeIntervalSinceReferenceDate: 12_345)
        XCTAssertTrue(
            WindowManager.isCachedKickValid(cachedLaunchDate: date, currentLaunchDate: date),
            "Same process (matching launchDate) — cached kick still applies"
        )
    }

    func testCacheInvalidOnPIDReuse() {
        // Process dies, macOS recycles the pid for a new process that
        // launches at a different wall-clock time. Stale cache would
        // skip the kick on the new process; its AX tree would never
        // build. Detect via launchDate mismatch.
        let original = Date(timeIntervalSinceReferenceDate: 10_000)
        let reused   = Date(timeIntervalSinceReferenceDate: 20_000)
        XCTAssertFalse(
            WindowManager.isCachedKickValid(cachedLaunchDate: original, currentLaunchDate: reused),
            "Different launchDate means pid was recycled — must re-kick the new process"
        )
    }

    func testCacheToleratesFloatRoundingOnly() {
        // launchDate doesn't re-measure between reads — the same process
        // should produce the same Date every time. The tolerance only
        // absorbs NSDate float-rounding (microseconds). Keep it tight
        // enough that a fast quit-and-relaunch (helper crash-respawn,
        // agent scripts) can't land inside it and skip the kick on a
        // genuinely fresh process.
        let cached          = Date(timeIntervalSinceReferenceDate: 12_345.00000)
        let tinyJitter      = Date(timeIntervalSinceReferenceDate: 12_345.00001)
        let fastRelaunch    = Date(timeIntervalSinceReferenceDate: 12_345.20000)

        XCTAssertTrue(
            WindowManager.isCachedKickValid(cachedLaunchDate: cached, currentLaunchDate: tinyJitter),
            "Microsecond-scale rounding should not force a re-kick"
        )
        XCTAssertFalse(
            WindowManager.isCachedKickValid(cachedLaunchDate: cached, currentLaunchDate: fastRelaunch),
            "A 200ms-later launchDate means a fresh process on the recycled pid — must re-kick"
        )
    }

    func testCacheFallsBackToCachedWhenCurrentUnavailable() {
        // NSRunningApplication(processIdentifier:) is flaky for some
        // short-lived helpers and sandbox edge cases. When the runtime
        // lookup returns nil but we have a cached kick, trust the cache.
        // If the process is genuinely dead, the subsequent focused-window
        // read will fail and the retry-once path will re-kick.
        let cached = Date()
        XCTAssertTrue(
            WindowManager.isCachedKickValid(cachedLaunchDate: cached, currentLaunchDate: nil),
            "Flaky NSRunningApplication read should not invalidate an existing cache entry"
        )
    }

    // MARK: - launchDateToCache (write-path decision)

    func testWriteCacheOnSuccessfulKickWithKnownLaunchDate() {
        let date = Date(timeIntervalSinceReferenceDate: 9_999)
        XCTAssertEqual(
            WindowManager.launchDateToCache(kickSucceeded: true, currentLaunchDate: date),
            date,
            "Happy path — successful kick + real launchDate should cache that date"
        )
    }

    func testDoNotCacheFailedKick() {
        // A failed AXUIElementSetAttributeValue call that got cached as
        // "kicked" would be invisible on every subsequent press. Return
        // nil so the caller leaves the cache empty and the next press
        // retries the kick from scratch.
        XCTAssertNil(
            WindowManager.launchDateToCache(kickSucceeded: false, currentLaunchDate: Date()),
            "Failed kick must not populate the cache"
        )
    }

    func testDoNotCacheWhenLaunchDateUnavailable() {
        // Tripwire for the `?? Date()` bug: writing "now at write-time"
        // in place of the real launchDate thrashes the cache. On the
        // next press, a successful NSRunningApplication read returns the
        // real (much earlier) launchDate, the comparison mismatches,
        // and we re-kick every press forever. Skipping the cache insert
        // is the correct behavior — next press re-kicks fresh.
        XCTAssertNil(
            WindowManager.launchDateToCache(kickSucceeded: true, currentLaunchDate: nil),
            "Must not cache a synthetic Date when launchDate lookup failed"
        )
    }

    // MARK: - Source-scan tripwires

    func testSetFrameStillTogglesEnhancedUserInterface() throws {
        // `setFrame` must flip `AXEnhancedUserInterface` to false around
        // the size/position write — Chrome/Firefox/Electron clamp AX
        // size writes when it's on. The restore is gated on real
        // VoiceOver presence (see WindowManager.setFrame comments) so
        // stale `true` bits from older builds get cleared instead of
        // ratcheted back. Real AX is out of reach for XCTest, so this
        // source-scan is the best tripwire available.
        let sourcePath = #filePath.replacingOccurrences(
            of: "/Tests/KatibWindowTests/AXKickPolicyTests.swift",
            with: "/Sources/KatibWindow/WindowManager.swift"
        )
        let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
        XCTAssertTrue(
            source.contains("AXEnhancedUserInterface") && source.contains("kCFBooleanFalse"),
            "setFrame must still flip AXEnhancedUserInterface off before the size write"
        )
        XCTAssertTrue(
            source.contains("isVoiceOverEnabled"),
            "setFrame restore must be gated on isVoiceOverEnabled — restoring unconditionally re-introduces the Chrome tab-switch shrink bug"
        )
    }
}
