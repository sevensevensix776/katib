import XCTest
@testable import KatibDictation

@MainActor
final class VoiceCommandMatcherTests: XCTestCase {

    override func setUp() async throws {
        VoiceCommandMatcher.shared.clear()
    }

    // MARK: - Normalization

    func testNormalizeLowercases() {
        XCTAssertEqual(VoiceCommandMatcher.normalize("SPLIT Left"), "split left")
    }

    func testNormalizeStripsTrailingPunctuation() {
        XCTAssertEqual(VoiceCommandMatcher.normalize("Split left."), "split left")
        XCTAssertEqual(VoiceCommandMatcher.normalize("Split left!!!"), "split left")
        XCTAssertEqual(VoiceCommandMatcher.normalize("Cancel?"), "cancel")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(VoiceCommandMatcher.normalize("   split left   "), "split left")
    }

    // MARK: - Matching

    func testMatchReturnsNilWhenNoPattern() {
        let matcher = VoiceCommandMatcher.shared
        matcher.register(VoiceCommand(
            displayName: "noop",
            patterns: ["^split left$"],
            outcome: .insertText("nope")
        ))
        XCTAssertNil(matcher.match(on: "hello world"))
    }

    func testMatchFiresOnExactPhrase() {
        let matcher = VoiceCommandMatcher.shared
        matcher.register(VoiceCommand(
            displayName: "split left",
            patterns: ["^split left$"],
            outcome: .insertText("LEFT")
        ))
        guard case .insertText(let s)? = matcher.match(on: "Split left.") else {
            return XCTFail("expected insertText outcome")
        }
        XCTAssertEqual(s, "LEFT")
    }

    func testFirstMatchWins() {
        let matcher = VoiceCommandMatcher.shared
        matcher.register(VoiceCommand(
            displayName: "a",
            patterns: ["^split left$"],
            outcome: .insertText("FIRST")
        ))
        matcher.register(VoiceCommand(
            displayName: "b",
            patterns: ["split"],
            outcome: .insertText("SECOND")
        ))
        guard case .insertText(let s)? = matcher.match(on: "split left") else {
            return XCTFail("expected insertText")
        }
        XCTAssertEqual(s, "FIRST")
    }

    func testMultiplePatternsAlternates() {
        let matcher = VoiceCommandMatcher.shared
        matcher.register(VoiceCommand(
            displayName: "paragraph",
            patterns: ["^new paragraph$", "^paragraph break$"],
            outcome: .insertText("\n\n")
        ))
        XCTAssertNotNil(matcher.match(on: "new paragraph"))
        XCTAssertNotNil(matcher.match(on: "paragraph break"))
        XCTAssertNil(matcher.match(on: "insert paragraph"))
    }

    func testExecuteOutcomeRoundtrip() {
        let matcher = VoiceCommandMatcher.shared
        var fired = false
        matcher.register(VoiceCommand(
            displayName: "cancel",
            patterns: ["^cancel$"],
            outcome: .execute { fired = true }
        ))
        guard case .execute(let action)? = matcher.match(on: "Cancel.") else {
            return XCTFail("expected execute")
        }
        action()
        XCTAssertTrue(fired)
    }

    // MARK: - Anchoring

    func testAnchoredPatternsRejectLongerInput() {
        let matcher = VoiceCommandMatcher.shared
        matcher.register(VoiceCommand(
            displayName: "cancel",
            patterns: ["^cancel$"],
            outcome: .insertText("X")
        ))
        // Anchored pattern — free-form text containing "cancel" should NOT match.
        XCTAssertNil(matcher.match(on: "I need to cancel that meeting"))
        XCTAssertNotNil(matcher.match(on: "cancel"))
    }
}
