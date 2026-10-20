import XCTest
@testable import KatibClipboard
import KatibCore

@MainActor
final class ClipboardManagerTests: XCTestCase {

    override func setUp() async throws {
        // CRITICAL: redirect persistence to a per-run temp folder BEFORE
        // doing anything else. Without this, every test's subsequent
        // mutations write to the user's real
        // `~/Library/Application Support/VoiceTools/clipboard-history.json`
        // and a `swift test` run silently destroys their clipboard
        // history. Cost of the bug: real user history wiped multiple times.
        ClipboardManager.shared._useIsolatedTestStore()
    }

    func testAppendStoresItem() {
        let cm = ClipboardManager.shared
        cm.append("hello")
        XCTAssertEqual(cm.items.count, 1)
        XCTAssertEqual(cm.items.first?.text, "hello")
    }

    func testAppendOrderIsNewestFirst() {
        let cm = ClipboardManager.shared
        cm.append("first")
        cm.append("second")
        cm.append("third")
        XCTAssertEqual(cm.items.map(\.text), ["third", "second", "first"])
    }

    func testAppendDedupesByMovingToTop() {
        let cm = ClipboardManager.shared
        cm.append("apple")
        cm.append("banana")
        cm.append("apple")
        XCTAssertEqual(cm.items.map(\.text), ["apple", "banana"])
    }

    func testCapacityCapIsEnforced() {
        let cm = ClipboardManager.shared
        cm.capacity = 3
        cm.append("a"); cm.append("b"); cm.append("c"); cm.append("d")
        XCTAssertEqual(cm.items.count, 3)
        XCTAssertEqual(cm.items.first?.text, "d")
        XCTAssertEqual(cm.items.last?.text, "b")
    }

    // MARK: - Load safety guard
    //
    // Pinned-down contract: if `loadFromDisk` would discard more than
    // half the on-disk items, the trim is refused. Catches init-order
    // bugs where `capacity` hasn't been pulled from settings yet — this
    // would have prevented the v1.30.3 incident that destroyed 7984
    // items down to 20 over a handful of launches.

    func testSafetyGuardDoesNotTripWhenNoTrim() {
        XCTAssertFalse(ClipboardManager.loadSafetyTripped(loadedCount: 100, postTrimCount: 100))
    }

    func testSafetyGuardDoesNotTripWhenTrimIsModest() {
        // Trim ~30% — well within the safe zone. User probably set capacity
        // = 70 and on-disk has 100 unpinned. Honor the trim.
        XCTAssertFalse(ClipboardManager.loadSafetyTripped(loadedCount: 100, postTrimCount: 70))
    }

    func testSafetyGuardDoesNotTripAtExactlyHalf() {
        // Boundary: 50% kept is the cutoff. Guard fires only on STRICTLY
        // less than half so a clean 1000 → 500 still persists.
        XCTAssertFalse(ClipboardManager.loadSafetyTripped(loadedCount: 1000, postTrimCount: 500))
    }

    func testSafetyGuardTripsWhenTrimWouldDestroyMostData() {
        // The v1.30.3 incident: 7984 on-disk, capacity=20 (init-order bug)
        // would persist a trim to 20 items. Refuse.
        XCTAssertTrue(ClipboardManager.loadSafetyTripped(loadedCount: 7984, postTrimCount: 20))
    }

    func testSafetyGuardTripsAtJustBelowHalf() {
        XCTAssertTrue(ClipboardManager.loadSafetyTripped(loadedCount: 1000, postTrimCount: 499))
    }

    func testSafetyGuardSafeOnEmptyStore() {
        // Fresh install — no items, no trim, no trip.
        XCTAssertFalse(ClipboardManager.loadSafetyTripped(loadedCount: 0, postTrimCount: 0))
    }

    // MARK: - Capacity reactivity

    func testLoweringCapacityAtRuntimeTrimsImmediately() {
        let cm = ClipboardManager.shared
        cm.capacity = 100
        for i in 0..<10 { cm.append("item-\(i)") }
        XCTAssertEqual(cm.items.count, 10)
        // User drops capacity in Settings → didSet runs → trim happens
        // without waiting for the next clipboard event. Without this, the
        // store stays at 10 until the next copy.
        cm.capacity = 5
        XCTAssertEqual(cm.items.count, 5)
        // Newest items survive (Maccy convention).
        XCTAssertEqual(cm.items.first?.text, "item-9")
    }

    // MARK: - Panel size calculation
    //
    // The picker panel size used to silently collapse to 1×1 because
    // contentViewController auto-resizing fought the contentRect. Now
    // it's computed by a pure helper so we can lock the math down.

    func testPanelSizeOnAsifsMBP() {
        // 14" MBP M-series: 1512×982 pt logical.
        let size = ClipboardPanelController.calculatePanelSize(
            screenSize: CGSize(width: 1512, height: 982)
        )
        // 1512 × 0.80 = 1209.6, within [1100, 1900]
        // 982  × 0.65 = 638.3,  floored to 600 minimum (NOT raised — 638 > 600)
        XCTAssertEqual(size.width, 1209.6, accuracy: 0.5)
        XCTAssertEqual(size.height, 638.3, accuracy: 0.5)
    }

    func testPanelSizeFloorsOnTinyDisplay() {
        // Imaginary 800×600 monitor — the floors keep the two-pane usable.
        let size = ClipboardPanelController.calculatePanelSize(
            screenSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(size.width, 1100, "Min width floor")
        XCTAssertEqual(size.height, 600, "Min height floor")
    }

    func testPanelSizeCapsOnLargeDisplay() {
        // 6K Pro Display XDR: 6016×3384.
        let size = ClipboardPanelController.calculatePanelSize(
            screenSize: CGSize(width: 6016, height: 3384)
        )
        XCTAssertEqual(size.width, 1900, "Max width cap")
        XCTAssertEqual(size.height, 1000, "Max height cap")
    }

    func testPanelSizeOn1440pMonitor() {
        // External 1440p QHD: 2560×1440. Mid-range — neither floor nor cap.
        let size = ClipboardPanelController.calculatePanelSize(
            screenSize: CGSize(width: 2560, height: 1440)
        )
        // 2560 × 0.80 = 2048, within [1100, 1900] → CAPPED at 1900
        // 1440 × 0.65 = 936,  within [600, 1000]
        XCTAssertEqual(size.width, 1900, accuracy: 0.5, "Width caps before fraction")
        XCTAssertEqual(size.height, 936, accuracy: 0.5)
    }

    func testRaisingCapacityIsNoOp() {
        let cm = ClipboardManager.shared
        cm.capacity = 5
        for i in 0..<3 { cm.append("item-\(i)") }
        cm.capacity = 100
        XCTAssertEqual(cm.items.count, 3)
    }

    func testImagesOnlyFilterReturnsEmptyWhenNoImages() {
        let cm = ClipboardManager.shared
        cm.append("text only")
        cm.append("more text")
        let imagesOnly = cm.visibleItems(matching: "", imagesOnly: true)
        XCTAssertTrue(imagesOnly.isEmpty)
        // Default (no filter) still shows both.
        XCTAssertEqual(cm.visibleItems(matching: "", imagesOnly: false).count, 2)
    }

    func testImagesOnlyFilterAndSearchAreOrthogonal() {
        let cm = ClipboardManager.shared
        cm.append("findme one")
        cm.append("other")
        // Search hits "findme"; imagesOnly drops them all (no images).
        XCTAssertEqual(cm.visibleItems(matching: "findme", imagesOnly: false).count, 1)
        XCTAssertEqual(cm.visibleItems(matching: "findme", imagesOnly: true).count, 0)
    }

    func testSettingCapacityToSameValueIsCompletelyInert() {
        // The bug that destroyed the user's history: init set capacity
        // via the computed-property setter, which fired persist() with
        // an empty items array BEFORE loadFromDisk ran. The setter must
        // short-circuit when the new value matches — no trim, no persist,
        // no observable side effect.
        let cm = ClipboardManager.shared
        cm.capacity = 1000
        cm.append("alpha")
        cm.append("beta")
        XCTAssertEqual(cm.items.count, 2)
        // Re-set to the same value. Items must survive untouched.
        cm.capacity = 1000
        XCTAssertEqual(cm.items.count, 2)
        XCTAssertEqual(cm.items.map(\.text), ["beta", "alpha"])
    }

    func testRemoveTakesItOut() {
        let cm = ClipboardManager.shared
        cm.append("keep")
        cm.append("drop")
        let drop = cm.items.first { $0.text == "drop" }!
        cm.remove(drop)
        XCTAssertEqual(cm.items.count, 1)
        XCTAssertEqual(cm.items.first?.text, "keep")
    }

    func testClearEmptiesList() {
        let cm = ClipboardManager.shared
        cm.append("x")
        cm.append("y")
        cm.clear()
        XCTAssertTrue(cm.items.isEmpty)
    }

    func testItemPreviewTruncatesLongText() {
        let long = String(repeating: "a", count: 200)
        let item = ClipboardItem(id: UUID(), text: long, capturedAt: Date())
        XCTAssertTrue(item.preview.count <= 81) // 80 chars + "…"
        XCTAssertTrue(item.preview.hasSuffix("…"))
    }

    func testItemPreviewStripsNewlines() {
        let item = ClipboardItem(id: UUID(), text: "line one\nline two", capturedAt: Date())
        XCTAssertFalse(item.preview.contains("\n"))
        XCTAssertTrue(item.preview.contains("line one line two"))
    }

    func testCodableRoundtrip() throws {
        let original = ClipboardItem(id: UUID(), text: "sample", capturedAt: Date())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
