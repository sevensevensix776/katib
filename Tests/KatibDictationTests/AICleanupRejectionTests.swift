import XCTest
@testable import KatibDictation

/// Guards against the v1.23.x "meta-response" regression where Foundation
/// Models returned prose ABOUT cleanup instead of the cleaned text. Tests
/// the ratio + word-overlap filters that back up the @Generable schema.
final class AICleanupRejectionTests: XCTestCase {

    // MARK: - Length inflation

    func testInflationAbove125PercentIsRejected() {
        let original = "hey what's up"
        let polished = String(repeating: "hey what's up! ", count: 3) // way longer
        XCTAssertNotNil(AICleanup.rejectionReason(polished: polished, original: original))
    }

    func testSlightlyLongerOutputIsAccepted() {
        // Cleanup can add punctuation + capitalize, making the output a few
        // characters longer. That should not trip the filter.
        let original = "hey whats up bro"
        let polished = "Hey, what's up bro?"
        XCTAssertNil(AICleanup.rejectionReason(polished: polished, original: original))
    }

    func testEmptyIsRejected() {
        XCTAssertNotNil(AICleanup.rejectionReason(polished: "", original: "hello there friend"))
    }

    // MARK: - Meta-response detection via word overlap

    func testDescribingTheCleanupProcessIsRejected() {
        let original = "um so like I think we should probably ship it you know"
        // Verbatim of the garbage output Asif actually saw in prod.
        let polished = "The transcription was processed to remove redundant restarts, stutters, fillers, and incorrect punctuation, preserving the original meaning and tone."
        let reason = AICleanup.rejectionReason(polished: polished, original: original)
        XCTAssertNotNil(reason, "Meta-response slipped past the guard")
    }

    func testParaphraseIsRejected() {
        let original = "I think we ought to build the thing next quarter and see what happens"
        // Same gist, different words — should fail the 70% overlap check.
        let polished = "We plan on building it later this year to observe results"
        XCTAssertNotNil(AICleanup.rejectionReason(polished: polished, original: original))
    }

    func testFillerRemovalIsAccepted() {
        let original = "um so I think like we should probably uh ship it you know"
        let polished = "I think we should probably ship it."
        XCTAssertNil(AICleanup.rejectionReason(polished: polished, original: original))
    }

    // MARK: - Word overlap edge cases

    func testWordOverlapOnShortInputStaysPermissive() {
        // Very short input — removing even one filler can tank the ratio.
        // We don't call polish() on short inputs in practice, but guard math
        // should still be sensible.
        let original = "yes please"
        let polished = "Yes, please."
        XCTAssertNil(AICleanup.rejectionReason(polished: polished, original: original))
    }

    func testWordOverlapComputesExpectedFraction() {
        let overlap = AICleanup.wordOverlap(
            polished: "the quick fox jumped",
            original: "the quick brown fox jumped high"
        )
        // Content words from original (len >= 3): the, quick, brown, fox, jumped, high → 6
        // Of those, in polished: the, quick, fox, jumped → 4
        XCTAssertEqual(overlap, 4.0 / 6.0, accuracy: 0.001)
    }
}
