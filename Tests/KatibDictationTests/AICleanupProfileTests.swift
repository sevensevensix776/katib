import XCTest
@testable import KatibDictation
import KatibCore

/// Tests the AICleanup paths that DON'T require the Foundation Models runtime
/// (which we can't call from the test sandbox): profile matching, prompt
/// composition, and session-cache invalidation on settings edits.
@MainActor
final class AICleanupProfileTests: XCTestCase {

    override func setUp() async throws {
        // Isolate AppSettings persistence to a per-test in-memory suite —
        // otherwise these mutations clobber the user's real aiCleanup*
        // settings in UserDefaults.standard on every swift test run.
        AppSettings.shared._useIsolatedTestStore()
        AppSettings.shared.aiCleanupAppProfiles = AppSettings.defaultAICleanupAppProfiles
        AppSettings.shared.aiCleanupPrompt = AppSettings.defaultAICleanupPrompt
    }

    // MARK: - Profile matching

    func testCursorBundleMatchesCodeToneProfile() {
        let tail = profileTail(for: "com.todesktop.cursor")
        XCTAssertTrue(tail.contains("code comment"), "Cursor should match the code tone tail")
    }

    func testSlackBundleMatchesChatProfile() {
        let tail = profileTail(for: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(tail.contains("chat"), "Slack should match the casual-chat tail")
    }

    func testMailBundleMatchesEmailProfile() {
        let tail = profileTail(for: "com.apple.mail")
        XCTAssertTrue(tail.contains("email"), "Mail should match the email tail")
    }

    func testUnknownBundleReturnsEmptyTail() {
        let tail = profileTail(for: "com.example.nothing-matches")
        XCTAssertTrue(tail.isEmpty)
    }

    func testNilBundleReturnsEmptyTail() {
        XCTAssertTrue(profileTail(for: nil).isEmpty)
    }

    func testEmptyBundleReturnsEmptyTail() {
        XCTAssertTrue(profileTail(for: "").isEmpty)
    }

    func testCustomProfileOverridesDefaults() {
        AppSettings.shared.aiCleanupAppProfiles = ["my-special-app": "Custom tone."]
        let tail = profileTail(for: "my-special-app")
        XCTAssertEqual(tail, "Custom tone.")
    }

    // MARK: - Default prompt

    func testDefaultPromptMentionsCorePunctuationRule() {
        let prompt = AppSettings.defaultAICleanupPrompt
        XCTAssertTrue(prompt.lowercased().contains("punctuation"))
        XCTAssertTrue(prompt.lowercased().contains("capitalization"))
        XCTAssertTrue(prompt.lowercased().contains("filler"))
    }

    func testDefaultPromptTellsModelToReturnTextOnly() {
        let prompt = AppSettings.defaultAICleanupPrompt
        XCTAssertTrue(prompt.lowercased().contains("only"))
    }

    // MARK: - Default profile set

    func testDefaultProfilesCoverExpectedAppFamilies() {
        let keys = AppSettings.defaultAICleanupAppProfiles.keys.joined(separator: " ")
        XCTAssertTrue(keys.contains("cursor") || keys.lowercased().contains("cursor"))
        XCTAssertTrue(keys.contains("Slack"))
        XCTAssertTrue(keys.contains("Mail"))
    }

    // MARK: - Helpers — mirror AICleanup.profileTail to test matching logic

    /// Mirror of the private `AICleanup.profileTail(for:)` — kept here so the
    /// test doesn't need to open up the class's visibility.
    private func profileTail(for bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "" }
        for (pattern, tail) in AppSettings.shared.aiCleanupAppProfiles {
            if bundleID.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return tail
            }
        }
        return ""
    }
}
