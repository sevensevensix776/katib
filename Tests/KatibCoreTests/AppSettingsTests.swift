import XCTest
@testable import KatibCore

@MainActor
final class AppSettingsTests: XCTestCase {

    override func setUp() async throws {
        // Redirect settings persistence to a per-test in-memory suite so
        // mutations don't write to the user's real UserDefaults.standard.
        AppSettings.shared._useIsolatedTestStore()
    }

    func testHotkeySideKeyCodes() {
        XCTAssertEqual(AppSettings.HotkeySide.leftOption.keyCode, 58)
        XCTAssertEqual(AppSettings.HotkeySide.rightOption.keyCode, 61)
    }

    func testHotkeySideDisplayName() {
        XCTAssertEqual(AppSettings.HotkeySide.leftOption.displayName, "Left Option")
        XCTAssertEqual(AppSettings.HotkeySide.rightOption.displayName, "Right Option")
    }

    func testHotkeyDescriptionIncludesHold() {
        let settings = AppSettings.shared
        XCTAssertTrue(settings.hotkeyDescription.contains("Option"))
        XCTAssertTrue(settings.hotkeyDescription.contains("hold"))
    }

    func testAllHotkeySidesIdentifiable() {
        // Driven by SwiftUI Picker — rawValue is the id, must be stable + unique.
        let ids = AppSettings.HotkeySide.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testMutatingHotkeySidePersists() {
        let settings = AppSettings.shared
        // Fresh isolated store for this test so the persistence
        // assertion below is deterministic regardless of other tests.
        let suite = settings._useIsolatedTestStore()
        let other: AppSettings.HotkeySide = .leftOption
        settings.hotkeySide = other
        XCTAssertEqual(suite.string(forKey: "hotkeySide"), other.rawValue,
                       "hotkeySide didSet must persist to the current defaults store")
    }
}
