import XCTest
@testable import KatibClipboard

/// Search benchmark on a real history file. Skipped unless
/// KATIB_BENCH_STORE points at a copy of clipboard-history.json (binary
/// plist). Never reads the live store.
///
/// Models typing "deploy" with every keystroke reaching the filter (the
/// worst case for the 80 ms debounce), right after a new copy:
///   before: the panel read `filtered` ~11 times per render, and the copy
///           had wiped the lowercase cache, so the first query ran cold.
///   after:  one filter per query, cache kept across the copy.
@MainActor
final class ClipboardSearchBenchmarkTests: XCTestCase {
    func testSearchOnRealHistory() throws {
        guard let path = ProcessInfo.processInfo.environment["KATIB_BENCH_STORE"] else {
            throw XCTSkip("set KATIB_BENCH_STORE to a copy of clipboard-history.json")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let items = try PropertyListDecoder().decode([ClipboardItem].self, from: data)
        let manager = ClipboardManager.shared
        manager._useIsolatedTestStore()

        let queries = ["d", "de", "dep", "depl", "deplo", "deploy"]
        let readsPerRender = 11

        func ms(_ block: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        // Before: cold cache on the first query, 11 full filters per query.
        manager._setItemsForTesting(items)
        var before = 0.0
        var coldFirst = 0.0
        for (i, q) in queries.enumerated() {
            let t = ms { for _ in 0..<readsPerRender { _ = manager.visibleItems(matching: q) } }
            if i == 0 { coldFirst = t }
            before += t
        }

        // After: cache already warm (kept across the copy), 1 filter per query.
        var after = 0.0
        var hits = 0
        for q in queries {
            after += ms { hits = manager.visibleItems(matching: q).count }
        }

        let cold = ms { manager._setItemsForTesting(items); _ = manager.visibleItems(matching: "d") }
        print("""
        BENCH clipboard search: \(items.count) clips, typing "deploy" (\(queries.count) queries), \(hits) matches
        BENCH before: \(String(format: "%.0f", before)) ms total, first query \(String(format: "%.0f", coldFirst)) ms (cold + 11 reads)
        BENCH after:  \(String(format: "%.0f", after)) ms total, \(String(format: "%.1f", after / Double(queries.count))) ms per query
        BENCH one cold filter alone: \(String(format: "%.0f", cold)) ms
        """)
        XCTAssertLessThan(after, before)

        // Same results as the old String.contains filter, on real data.
        for q in queries + ["http", "acme", "é", "ü", "—", "776", " the "] {
            // visibleItems trims the query, so the reference does too.
            let lowered = q.trimmingCharacters(in: .whitespaces).lowercased()
            let old = Set(items.filter { $0.text.lowercased().contains(lowered) }.map(\.id))
            let new = Set(manager.visibleItems(matching: q).map(\.id))
            print("BENCH same-results \(q.debugDescription): old \(old.count) new \(new.count) " +
                  "only-old \(old.subtracting(new).count) only-new \(new.subtracting(old).count)")
            XCTAssertTrue(old == new, "query \(q.debugDescription) differs")
        }
    }
}

final class ClipboardUTF8ContainsTests: XCTestCase {
    func testMatchesStringContains() {
        let cases: [(String, String)] = [
            ("deploy the api", "deploy"), ("deploy", "deployment"), ("", "a"), ("abc", ""),
            ("café au lait", "café"), ("naïve", "ï"), ("a — b", "—"), ("😀 ok", "😀"), ("xyz", "q")
        ]
        for (hay, needle) in cases {
            XCTAssertEqual(ClipboardManager.utf8Contains(hay, needle), needle.isEmpty || hay.contains(needle),
                           "\(hay) / \(needle)")
        }
    }
}
