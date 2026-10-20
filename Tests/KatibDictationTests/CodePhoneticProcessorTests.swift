import XCTest
@testable import KatibDictation

final class CodePhoneticProcessorTests: XCTestCase {

    // MARK: - Positive — real developer speech

    func testHyphenatedIdentifier() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("acme dash api"),
            "acme-api"
        )
    }

    func testChainedHyphensCollapseInOrder() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("acme dash api dash service"),
            "acme-api-service"
        )
    }

    func testSlashSeparator() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("src slash modules slash auth"),
            "src/modules/auth"
        )
    }

    func testDotSeparator() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("config dot yaml"),
            "config.yaml"
        )
    }

    func testUnderscoreSeparator() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("team underscore dictionary"),
            "team_dictionary"
        )
    }

    func testDoubleDashBeatsSingleDash() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("run dash dash verbose flag"),
            "run--verbose flag"
        )
    }

    // MARK: - Negative — normal English stays untouched

    func testStandaloneDashBetweenStopwordsIsUntouched() {
        // "I need to dash to the store" — the stopwords around "dash"
        // mean it's not a developer separator.
        XCTAssertEqual(
            CodePhoneticProcessor.process("I need to dash to the store"),
            "I need to dash to the store"
        )
    }

    func testBothSidesAreDevTokensSoCollapseFires() {
        // "field" and "input" are both non-stopword alphanumerics, so the
        // rule fires — correct behavior in a code-editor context. Users
        // who don't want this pattern in pure prose should turn code mode
        // off for that bundle.
        XCTAssertEqual(
            CodePhoneticProcessor.process("the field slash input was empty"),
            "the field/input was empty"
        )
    }

    func testDashOnlyApplicableWhenBothSidesAreNonStopwords() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("to dash api"),
            "to dash api"  // "to" is a stopword → don't collapse
        )
    }

    // MARK: - Mixed prose + code

    func testCodeFollowedByProseKeepsCode() {
        // The identifier collapses, the English tail stays natural.
        XCTAssertEqual(
            CodePhoneticProcessor.process("deploy acme dash api and then wait"),
            "deploy acme-api and then wait"
        )
    }

    func testCaseInsensitiveTrigger() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("Acme Dash API"),
            "Acme-API"
        )
    }

    // MARK: - Boundary conditions

    func testEmptyInputIsEmpty() {
        XCTAssertEqual(CodePhoneticProcessor.process(""), "")
    }

    func testNoTriggerLeavesTextUnchanged() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("nothing to see here"),
            "nothing to see here"
        )
    }

    func testTriggerAtStartWithoutLeftTokenStays() {
        // "dash main" at start — no token before "dash", leave alone.
        XCTAssertEqual(
            CodePhoneticProcessor.process("dash main"),
            "dash main"
        )
    }

    func testTriggerAtEndWithoutRightTokenStays() {
        XCTAssertEqual(
            CodePhoneticProcessor.process("run with dash"),
            "run with dash"
        )
    }
}
