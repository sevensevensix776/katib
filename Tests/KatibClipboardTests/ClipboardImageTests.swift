import XCTest
@testable import KatibClipboard

/// Image path: `ClipboardImage` preview formatting + `isImage` flag +
/// preview collision with text dedup.
final class ClipboardImageTests: XCTestCase {

    private func makeImage(width: Int = 640, height: Int = 480, bytes: Int = 120_000) -> ClipboardImage {
        ClipboardImage(
            filename: "\(UUID().uuidString).png",
            width: width, height: height, bytes: bytes,
            thumbnail: Data()
        )
    }

    func testImageItemIsMarkedAsImage() {
        let item = ClipboardItem(
            id: UUID(), text: "",
            capturedAt: Date(), pinned: false,
            sourceApp: nil, image: makeImage()
        )
        XCTAssertTrue(item.isImage)
    }

    func testTextItemIsNotMarkedAsImage() {
        let item = ClipboardItem(id: UUID(), text: "hi", capturedAt: Date())
        XCTAssertFalse(item.isImage)
    }

    func testImagePreviewIncludesDimensions() {
        let item = ClipboardItem(
            id: UUID(), text: "", capturedAt: Date(),
            image: makeImage(width: 1920, height: 1080, bytes: 420_000)
        )
        XCTAssertTrue(item.preview.contains("1920"))
        XCTAssertTrue(item.preview.contains("1080"))
    }

    func testImagePreviewHasHumanBytes() {
        let item = ClipboardItem(
            id: UUID(), text: "", capturedAt: Date(),
            image: makeImage(bytes: 1_500_000)
        )
        // ByteCountFormatter default string should contain "MB" for 1.5 MB.
        XCTAssertTrue(item.preview.contains("MB"))
    }

    func testEqualityDistinguishesImageFromText() {
        let now = Date()
        let shared = UUID()
        let text = ClipboardItem(id: shared, text: "x", capturedAt: now)
        let image = ClipboardItem(
            id: shared, text: "x", capturedAt: now,
            image: makeImage()
        )
        XCTAssertNotEqual(text, image)
    }
}
