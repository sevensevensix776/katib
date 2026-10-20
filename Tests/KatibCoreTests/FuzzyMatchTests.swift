import XCTest
@testable import KatibCore

final class FuzzyMatchTests: XCTestCase {

    // MARK: - Basic matching

    func testEmptyQueryReturnsPositive() {
        XCTAssertGreaterThan(FuzzyMatch.score(query: "", candidate: "anything"), 0)
    }

    func testCompleteMismatchReturnsZero() {
        XCTAssertEqual(FuzzyMatch.score(query: "xyz", candidate: "abc"), 0)
    }

    func testQueryLongerThanCandidateReturnsZero() {
        XCTAssertEqual(FuzzyMatch.score(query: "abcdef", candidate: "abc"), 0)
    }

    func testExactMatchScoresHigher() {
        let exact = FuzzyMatch.score(query: "split", candidate: "split")
        let partial = FuzzyMatch.score(query: "split", candidate: "splint")
        XCTAssertGreaterThan(exact, partial)
    }

    // MARK: - Ordering matters

    func testOutOfOrderCharsFail() {
        // "ba" has no valid ordering in "cab" — 'b' first, then 'a' would need
        // to come after, but 'a' only appears before 'b'.
        XCTAssertEqual(FuzzyMatch.score(query: "ba", candidate: "cab"), 0)
    }

    // MARK: - Separator bonus

    func testMatchAfterSpaceScoresHigher() {
        let afterSpace = FuzzyMatch.score(query: "l", candidate: "split left")
        let midWord = FuzzyMatch.score(query: "l", candidate: "splint")
        XCTAssertGreaterThan(afterSpace, midWord)
    }

    // MARK: - Separator bonus dominates over scattered

    func testPrefixOnWordStartBeatsMidwordMatch() {
        let atStart = FuzzyMatch.score(query: "spl", candidate: "Split left")
        let midWord = FuzzyMatch.score(query: "spl", candidate: "Unsplit window")
        XCTAssertGreaterThan(atStart, midWord)
    }

    // MARK: - Palette-realistic cases

    func testPaletteRanking_SplitMatchesLeftAndRight() {
        let left = FuzzyMatch.score(query: "split", candidate: "Split left")
        let right = FuzzyMatch.score(query: "split", candidate: "Split right")
        XCTAssertGreaterThan(left, 0)
        XCTAssertGreaterThan(right, 0)
        // Both should score similarly — they both match the query prefix perfectly.
        XCTAssertEqual(left, right)
    }

    func testPaletteRanking_CaseInsensitive() {
        let lower = FuzzyMatch.score(query: "split", candidate: "split left")
        let upper = FuzzyMatch.score(query: "SPLIT", candidate: "split left")
        XCTAssertEqual(lower, upper)
    }

    func testPaletteRanking_PrefixBeatsMidword() {
        let prefix = FuzzyMatch.score(query: "max", candidate: "Maximize")
        let midword = FuzzyMatch.score(query: "max", candidate: "Almost maximize")
        XCTAssertGreaterThan(prefix, midword)
    }
}
