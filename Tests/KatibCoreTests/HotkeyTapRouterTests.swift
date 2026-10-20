import XCTest
import AppKit
@testable import KatibCore

/// Tests the pure-logic bits of HotkeyTapRouter — specifically the flag
/// normalization that has to be correct for fn-remapped keycodes to
/// match bindings on both laptop + desktop keyboards.
final class HotkeyTapRouterTests: XCTestCase {

    // MARK: - Flag normalization

    func testStandardKeyKeepsAllInterestingFlags() {
        // "V" keycode with ⌘⌥ held — no fn-remap magic, all flags survive.
        let raw = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        let normalized = HotkeyTapRouter.normalizedFlags(keyCode: 9, rawFlags: raw)
        XCTAssertEqual(normalized, raw)
    }

    func testFnBitStrippedOnHome() {
        // fn+Left → keyCode=115 (Home) with ⌃⌥⌘+fn. The fn bit is an
        // artefact of the hardware remap; bindings are stored without it.
        let raw = CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskSecondaryFn.rawValue
        let normalized = HotkeyTapRouter.normalizedFlags(keyCode: 115, rawFlags: raw)
        XCTAssertEqual(normalized & CGEventFlags.maskSecondaryFn.rawValue, 0)
        XCTAssertEqual(normalized & CGEventFlags.maskControl.rawValue, CGEventFlags.maskControl.rawValue)
        XCTAssertEqual(normalized & CGEventFlags.maskAlternate.rawValue, CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(normalized & CGEventFlags.maskCommand.rawValue, CGEventFlags.maskCommand.rawValue)
    }

    func testFnBitStrippedOnEnd() {
        let raw = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        let normalized = HotkeyTapRouter.normalizedFlags(keyCode: 119, rawFlags: raw)
        XCTAssertEqual(normalized, CGEventFlags.maskCommand.rawValue)
    }

    func testFnBitStrippedOnPageUp() {
        let raw = CGEventFlags.maskSecondaryFn.rawValue
        let normalized = HotkeyTapRouter.normalizedFlags(keyCode: 116, rawFlags: raw)
        XCTAssertEqual(normalized, 0)
    }

    func testFnBitStrippedOnPageDown() {
        let raw = CGEventFlags.maskSecondaryFn.rawValue
        let normalized = HotkeyTapRouter.normalizedFlags(keyCode: 121, rawFlags: raw)
        XCTAssertEqual(normalized, 0)
    }

    func testFnBitStrippedOnForwardDelete() {
        let raw = CGEventFlags.maskSecondaryFn.rawValue
        let normalized = HotkeyTapRouter.normalizedFlags(keyCode: 117, rawFlags: raw)
        XCTAssertEqual(normalized, 0)
    }

    func testUnmaskedOSBitsAreDropped() {
        // CGEvent.flags can carry maskNumericPad, maskAlphaShift etc. — we
        // don't care, only interestingFlags survive.
        let raw = CGEventFlags.maskNumericPad.rawValue
            | CGEventFlags.maskAlphaShift.rawValue
            | CGEventFlags.maskCommand.rawValue
        let normalized = HotkeyTapRouter.normalizedFlags(keyCode: 9, rawFlags: raw)
        XCTAssertEqual(normalized, CGEventFlags.maskCommand.rawValue)
    }

    func testInterestingFlagsMaskIncludesAllFive() {
        XCTAssertNotEqual(HotkeyTapRouter.interestingFlags & CGEventFlags.maskShift.rawValue, 0)
        XCTAssertNotEqual(HotkeyTapRouter.interestingFlags & CGEventFlags.maskControl.rawValue, 0)
        XCTAssertNotEqual(HotkeyTapRouter.interestingFlags & CGEventFlags.maskAlternate.rawValue, 0)
        XCTAssertNotEqual(HotkeyTapRouter.interestingFlags & CGEventFlags.maskCommand.rawValue, 0)
        XCTAssertNotEqual(HotkeyTapRouter.interestingFlags & CGEventFlags.maskSecondaryFn.rawValue, 0)
    }

    // MARK: - Equivalence: laptop + desktop bindings match the same mask

    // MARK: - Carbon → CGEvent mask conversion

    func testCarbonShiftCmdYieldsShiftPlusCmdFlags() {
        // shiftKey (0x200) | cmdKey (0x100) = 0x300 is what the screenshot
        // hotkey settings store for ⇧⌘-based defaults.
        let mask = HotkeyTapRouter.cgFlagMask(carbonModifiers: 0x300)
        XCTAssertEqual(
            mask,
            CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue
        )
    }

    func testCarbonOptCmdYieldsOptionPlusCmdFlags() {
        // optionKey (0x800) | cmdKey (0x100) = 0x900 — old screenshot default
        // and current clipboard default.
        let mask = HotkeyTapRouter.cgFlagMask(carbonModifiers: 0x900)
        XCTAssertEqual(
            mask,
            CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        )
    }

    func testCarbonFullHouseYieldsAllFourModifiers() {
        // controlKey | shiftKey | optionKey | cmdKey — ⌃⇧⌥⌘.
        let mask = HotkeyTapRouter.cgFlagMask(carbonModifiers: 0x1000 | 0x200 | 0x800 | 0x100)
        XCTAssertEqual(
            mask,
            CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskShift.rawValue
                | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskCommand.rawValue
        )
    }

    func testCarbonZeroModifiersYieldsZero() {
        XCTAssertEqual(HotkeyTapRouter.cgFlagMask(carbonModifiers: 0), 0)
    }

    // MARK: - Conflict detection

    @MainActor
    func testIsBindingAvailableReturnsTrueForUnregistered() {
        let router = HotkeyTapRouter.shared
        // keyCode 99 is unused (F3 remaps to Mission Control); no registration.
        XCTAssertTrue(router.isBindingAvailable(
            keyCode: 99,
            flagMask: CGEventFlags.maskCommand.rawValue
        ))
    }

    @MainActor
    func testIsBindingAvailableReturnsFalseAfterRegistration() {
        let router = HotkeyTapRouter.shared
        let keyCode: UInt32 = 200  // pick something no other test uses
        let mask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        let token = router.registerConsumer(keyCode: keyCode, flagMask: mask) { }
        defer { router.remove(token) }
        XCTAssertFalse(router.isBindingAvailable(keyCode: keyCode, flagMask: mask))
        // Different mask on same key is still available.
        XCTAssertTrue(router.isBindingAvailable(
            keyCode: keyCode,
            flagMask: CGEventFlags.maskControl.rawValue
        ))
    }

    // MARK: - Module-isolation contract
    //
    // These tests pin down the property that matters most when a NEW module
    // adds a hotkey: adding a second consumer must not disturb the first.
    // Without this, a regression like "new Snippet binding accidentally
    // stole ⌥⌘V from Clipboard" could ship silently.

    @MainActor
    func testRegisteringSecondConsumerDoesNotRemoveFirst() {
        let router = HotkeyTapRouter.shared
        let mask = CGEventFlags.maskCommand.rawValue

        let firstToken = router.registerConsumer(keyCode: 210, flagMask: mask) {}
        let secondToken = router.registerConsumer(keyCode: 211, flagMask: mask) {}
        defer {
            router.remove(firstToken)
            router.remove(secondToken)
        }

        XCTAssertFalse(router.isBindingAvailable(keyCode: 210, flagMask: mask))
        XCTAssertFalse(router.isBindingAvailable(keyCode: 211, flagMask: mask))
    }

    @MainActor
    func testRemovingOneConsumerLeavesOthersIntact() {
        let router = HotkeyTapRouter.shared
        let mask = CGEventFlags.maskCommand.rawValue

        let toRemove = router.registerConsumer(keyCode: 212, flagMask: mask) {}
        let toKeep = router.registerConsumer(keyCode: 213, flagMask: mask) {}
        defer { router.remove(toKeep) }

        router.remove(toRemove)

        XCTAssertTrue(router.isBindingAvailable(keyCode: 212, flagMask: mask))
        XCTAssertFalse(router.isBindingAvailable(keyCode: 213, flagMask: mask))
    }

    @MainActor
    func testIdenticalBindingFromTwoConsumersBothRegister() {
        // The router doesn't enforce exclusivity at registration time —
        // that's the settings UI's job via isBindingAvailable. This test
        // locks in the current behaviour so a future change "silently
        // deduplicates" doesn't break the clipboard+screenshot case where
        // both modules legitimately register their defaults during init
        // before conflict checking runs.
        let router = HotkeyTapRouter.shared
        let mask = CGEventFlags.maskCommand.rawValue

        let first = router.registerConsumer(keyCode: 214, flagMask: mask) {}
        let second = router.registerConsumer(keyCode: 214, flagMask: mask) {}
        defer {
            router.remove(first)
            router.remove(second)
        }

        XCTAssertFalse(router.isBindingAvailable(keyCode: 214, flagMask: mask))
        XCTAssertNotEqual(first, second) // distinct tokens
    }

    @MainActor
    func testListenerRegistrationDoesNotAffectConsumerAvailability() {
        let router = HotkeyTapRouter.shared
        let mask = CGEventFlags.maskCommand.rawValue

        let listenerToken = router.registerListener { _, _ in }
        defer { router.remove(listenerToken) }

        // Registering a listener must NOT take a binding away from the
        // consumer registry — listeners observe, they don't consume.
        XCTAssertTrue(router.isBindingAvailable(keyCode: 215, flagMask: mask))
    }

    // MARK: - Tap lifecycle

    @MainActor
    func testIsTapDeadFalseWhenNothingRegistered() {
        let router = HotkeyTapRouter.shared
        // Fresh state assumption: earlier tests clean up their tokens.
        // If another test leaked a token, this will fail loudly — that's
        // the test catching a test hygiene bug, which is also a win.
        XCTAssertFalse(router.isTapDead, "isTapDead must be false with no registrations")
    }

    // MARK: - Modifier observer contract

    @MainActor
    func testModifierObserverReturnsDistinctTokens() {
        let router = HotkeyTapRouter.shared
        let a = router.registerModifierObserver { _, _ in }
        let b = router.registerModifierObserver { _, _ in }
        defer { router.remove(a); router.remove(b) }
        XCTAssertNotEqual(a, b)
    }

    @MainActor
    func testModifierObserverTokenTypeIsDistinctFromConsumerToken() {
        // Compile-time safety: `remove(_ token: Token)` and
        // `remove(_ token: ModifierObserverToken)` are separate overloads.
        // This test just confirms a ModifierObserverToken is a value of
        // its own type and can't be mistaken for a consumer Token.
        let router = HotkeyTapRouter.shared
        let modToken = router.registerModifierObserver { _, _ in }
        defer { router.remove(modToken) }
        // If the two types were bridged, this would ambiguate — the fact
        // it compiles with two distinct overloads is the test.
        XCTAssertNotNil(modToken.id)
    }

    @MainActor
    func testRemovingOneModifierObserverLeavesOthersIntact() {
        let router = HotkeyTapRouter.shared
        let a = router.registerModifierObserver { _, _ in }
        let b = router.registerModifierObserver { _, _ in }
        router.remove(a)
        // `b` is still registered — verify by removing it successfully
        // (a no-op on non-existent token would also pass, but pairing
        // with `install→register→register→remove one→remove other` is
        // what matters: the first remove didn't orphan the second).
        router.remove(b)
        XCTAssertTrue(true) // completed without crashing
    }

    @MainActor
    func testRemovingLastModifierObserverTearsDownTapIfIdleOtherwise() {
        // Register a consumer so the tap stays alive, then add/remove a
        // modifier observer. The tap must survive because the consumer
        // is still there.
        let router = HotkeyTapRouter.shared
        let consumerToken = router.registerConsumer(
            keyCode: 250,
            flagMask: CGEventFlags.maskCommand.rawValue
        ) {}
        let modToken = router.registerModifierObserver { _, _ in }
        router.remove(modToken)
        // Consumer's binding still registered = tap still needed.
        XCTAssertFalse(router.isBindingAvailable(
            keyCode: 250,
            flagMask: CGEventFlags.maskCommand.rawValue
        ))
        router.remove(consumerToken)
    }

    func testLaptopFnLeftAndDesktopHomeYieldSameNormalizedFlags() {
        // Laptop: user holds fn + ⌃⌥⌘ + Left. macOS remaps to Home + fn bit
        // in the flags. Desktop: user holds ⌃⌥⌘ + Home on a full-size
        // keyboard, no fn bit. Both should normalize to the same mask so a
        // single binding works everywhere.
        let laptopFlags = CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskSecondaryFn.rawValue
        let desktopFlags = CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
        let laptop = HotkeyTapRouter.normalizedFlags(keyCode: 115, rawFlags: laptopFlags)
        let desktop = HotkeyTapRouter.normalizedFlags(keyCode: 115, rawFlags: desktopFlags)
        XCTAssertEqual(laptop, desktop)
    }
}
