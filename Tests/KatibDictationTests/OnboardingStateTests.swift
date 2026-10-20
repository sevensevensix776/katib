import XCTest
@testable import KatibDictation

/// The welcome window's dead ends a fresh-Mac tester hit or could hit.
@MainActor
final class OnboardingStateTests: XCTestCase {
    /// Nothing heard used to leave the test on "Waiting" with no feedback.
    func testMissedDictationSaysSoThenAHeardOneUnlocks() {
        let state = OnboardingState(step: .test)
        state.recordTestResult(nil)
        XCTAssertTrue(state.testMissed)
        XCTAssertFalse(state.canAdvance)

        state.recordTestResult("hello hello hello")
        XCTAssertEqual(state.testTranscript, "hello hello hello")
        XCTAssertFalse(state.testMissed)
        XCTAssertTrue(state.canAdvance)
    }

    /// A dictation that ends after the user clicked Back must not complete
    /// a step they are no longer on.
    func testResultArrivingAfterLeavingTheStepIsIgnored() {
        let state = OnboardingState(step: .permissions)
        state.recordTestResult("late")
        XCTAssertNil(state.testTranscript)
    }

    /// A new Screen Recording grant can need a restart, so it must not block
    /// the permissions step; dictation's three permissions do.
    func testPermissionsAdvanceWithoutScreenRecording() {
        let state = OnboardingState(step: .permissions)
        state.micGranted = true
        state.speechGranted = true
        XCTAssertFalse(state.canAdvance)
        state.accessibilityGranted = true
        state.screenRecordingGranted = false
        XCTAssertTrue(state.canAdvance)
    }
}
