import XCTest
@testable import KatibWindow
import Carbon.HIToolbox

final class WindowBindingsTests: XCTestCase {

    // MARK: - Rectangle preset

    func testRectanglePresetCoversAllHalvesAndQuarters() {
        let bindings = WindowPreset.rectangle.bindings()
        let required: [WindowAction] = [
            .leftHalf, .rightHalf, .topHalf, .bottomHalf,
            .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
            .maximize, .center
        ]
        for action in required {
            XCTAssertNotNil(bindings[action], "\(action) missing from Rectangle preset")
        }
    }

    func testRectangleHalvesUseArrowKeysWithCtrlOpt() {
        let bindings = WindowPreset.rectangle.bindings()
        let left = bindings[.leftHalf]!
        XCTAssertEqual(left.keyCode, 123) // ←
        XCTAssertEqual(left.modifiers, UInt32(controlKey | optionKey))
        XCTAssertTrue(left.displayString.contains("⌃"))
        XCTAssertTrue(left.displayString.contains("⌥"))
        XCTAssertTrue(left.displayString.contains("←"))
    }

    func testRectangleMaximizeIsEnter() {
        let bindings = WindowPreset.rectangle.bindings()
        let max = bindings[.maximize]!
        XCTAssertEqual(max.keyCode, 36) // ↩
    }

    // MARK: - BetterSnapTool preset

    func testBSTPresetMatchesAsifsActualBST() {
        // Decoded from his BST plist: ⌃⌥⌘ + Home/End/PageUp.
        let bindings = WindowPreset.bettersnaptool.bindings()
        let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)
        XCTAssertEqual(bindings[.leftHalf]?.keyCode, UInt32(kVK_Home))
        XCTAssertEqual(bindings[.leftHalf]?.modifiers, ctrlOptCmd)
        XCTAssertEqual(bindings[.rightHalf]?.keyCode, UInt32(kVK_End))
        XCTAssertEqual(bindings[.maximize]?.keyCode, UInt32(kVK_PageUp))
    }

    func testBSTPresetLeavesQuartersUnbound() {
        let bindings = WindowPreset.bettersnaptool.bindings()
        XCTAssertNil(bindings[.topLeftQuarter])
    }

    // MARK: - Empty preset

    func testEmptyPresetHasNoBindings() {
        XCTAssertTrue(WindowPreset.empty.bindings().isEmpty)
    }

    // MARK: - WindowBinding display formatting

    func testDisplayStringShowsModifiersInCanonicalOrder() {
        let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)
        let binding = WindowBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: ctrlOptCmd)
        let s = binding.displayString
        // Carbon canonical order: Control, Option, Shift, Command
        XCTAssertEqual(s.firstIndex(of: "⌃")?.utf16Offset(in: s) ?? -1, 0)
        // Command symbol always comes before the key letter.
        let cmdIdx = s.firstIndex(of: "⌘")?.utf16Offset(in: s) ?? -1
        let keyIdx = s.firstIndex(of: "V")?.utf16Offset(in: s) ?? -1
        XCTAssertLessThan(cmdIdx, keyIdx)
    }

    func testUnboundBindingHasEmptyDisplayString() {
        let binding = WindowBinding()
        XCTAssertTrue(binding.displayString.isEmpty)
        XCTAssertFalse(binding.isBound)
    }

    // MARK: - keyCodeName coverage

    func testKeyCodeNameMapsArrows() {
        XCTAssertEqual(keyCodeName(UInt16(kVK_LeftArrow)), "←")
        XCTAssertEqual(keyCodeName(UInt16(kVK_RightArrow)), "→")
        XCTAssertEqual(keyCodeName(UInt16(kVK_UpArrow)), "↑")
        XCTAssertEqual(keyCodeName(UInt16(kVK_DownArrow)), "↓")
    }

    func testKeyCodeNameMapsCommonKeys() {
        XCTAssertEqual(keyCodeName(UInt16(kVK_Return)), "↩")
        XCTAssertEqual(keyCodeName(UInt16(kVK_Space)), "Space")
        XCTAssertEqual(keyCodeName(UInt16(kVK_Escape)), "⎋")
        XCTAssertEqual(keyCodeName(UInt16(kVK_Tab)), "⇥")
    }

    func testKeyCodeNameFallbackForUnknown() {
        // Keycode 200 is outside our table — should return "?200" fallback.
        XCTAssertEqual(keyCodeName(200), "?200")
    }
}
