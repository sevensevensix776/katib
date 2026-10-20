import XCTest
@testable import KatibLauncher

/// Tests cover the pure surfaces — predicate construction and the
/// min-query-length gate. The actual Spotlight roundtrip isn't tested
/// because it depends on the user's Mac index state and would be brittle
/// in CI; manual smoke tests cover that path.
final class FileSearchProviderTests: XCTestCase {

    // MARK: - Predicate

    func testPredicateMatchesDisplayName() {
        let p = FileSearchProvider.predicate(for: "report")
        let format = p.predicateFormat
        XCTAssertTrue(format.contains("kMDItemDisplayName"), "format was \(format)")
        XCTAssertTrue(format.contains("LIKE[cd]"), "format was \(format)")
        XCTAssertTrue(format.contains("*report*"), "format was \(format)")
    }

    func testPredicateExcludesAppBundles() {
        let p = FileSearchProvider.predicate(for: "anything")
        let format = p.predicateFormat
        XCTAssertTrue(
            format.contains("com.apple.application-bundle"),
            "predicate must exclude app bundles to avoid double-counting AppLauncherIndex; format was \(format)"
        )
    }

    func testPredicateAcceptsSpecialCharacters() {
        // %@-substitution should keep these literal — no formatter
        // injection. We're not asserting Spotlight match behavior, just
        // that constructing the predicate doesn't crash.
        _ = FileSearchProvider.predicate(for: "weird ' \" %@ name")
        _ = FileSearchProvider.predicate(for: "")
        _ = FileSearchProvider.predicate(for: "/path/like/string")
    }

    // MARK: - Query gate

    @MainActor
    func testShortQueryClearsResults() async throws {
        let provider = FileSearchProvider(limit: 10, minQueryLength: 3, debounce: .milliseconds(10))
        provider.search("ab")
        // Debounce has nothing to fire — result must be empty synchronously.
        XCTAssertEqual(provider.results, [])
    }

    @MainActor
    func testEmptyQueryClearsResults() async throws {
        let provider = FileSearchProvider(limit: 10, minQueryLength: 2, debounce: .milliseconds(10))
        provider.search("")
        XCTAssertEqual(provider.results, [])
    }

    @MainActor
    func testWhitespaceOnlyQueryClearsResults() async throws {
        let provider = FileSearchProvider(limit: 10, minQueryLength: 2, debounce: .milliseconds(10))
        provider.search("   ")
        XCTAssertEqual(provider.results, [])
    }

    @MainActor
    func testCancelClearsResults() async throws {
        let provider = FileSearchProvider(limit: 10, minQueryLength: 2, debounce: .milliseconds(10))
        provider.search("hello")
        provider.cancel()
        XCTAssertEqual(provider.results, [])
    }
}
