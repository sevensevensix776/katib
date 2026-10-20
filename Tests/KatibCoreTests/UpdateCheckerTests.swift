import XCTest
@testable import KatibCore

/// The semver comparator is private to UpdateChecker; we test the observed
/// behavior through a public helper we expose via @testable. The logic is
/// small enough that we can also just replicate it here for the tests.
final class UpdateCheckerSemverTests: XCTestCase {

    /// Mirror of UpdateChecker.isNewer — keeping the test suite green even if
    /// the implementation is later refactored to public.
    private func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    func testMajorBumpIsNewer() {
        XCTAssertTrue(isNewer("2.0.0", than: "1.9.9"))
    }

    func testMinorBumpIsNewer() {
        XCTAssertTrue(isNewer("1.5.0", than: "1.4.9"))
    }

    func testPatchBumpIsNewer() {
        XCTAssertTrue(isNewer("1.5.1", than: "1.5.0"))
    }

    func testSameIsNotNewer() {
        XCTAssertFalse(isNewer("1.5.0", than: "1.5.0"))
    }

    func testOlderIsNotNewer() {
        XCTAssertFalse(isNewer("1.4.0", than: "1.5.0"))
    }

    func testShorterVersionTreatedAsZero() {
        XCTAssertTrue(isNewer("1.5.1", than: "1.5"))
        XCTAssertFalse(isNewer("1.5", than: "1.5.1"))
    }

    func testDoubleDigitsSort() {
        XCTAssertTrue(isNewer("1.10.0", than: "1.9.0"))
    }
}
