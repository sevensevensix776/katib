import XCTest
@testable import KatibDictation

final class TranscriptionHistoryTests: XCTestCase {
    private var pacific: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func line(_ ts: String, words: Int, seconds: Double) -> String {
        #"{"timestamp":"\#(ts)","engine":"katib","app":"Slack","durationSeconds":\#(seconds),"wordCount":\#(words),"charCount":1}"#
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    /// 2026-11-20, 5 pm Pacific is already 2026-11-21 in UTC. The old UTC
    /// prefix test dropped the whole Nov 20 day at this moment (4 pm PST).
    func testDayDoesNotRollOverAtFourPmPacific() {
        let content = [
            line("2026-11-20T17:00:00.000Z", words: 10, seconds: 4),  // 9:00 am PST Nov 20
            line("2026-11-21T00:30:00.000Z", words: 20, seconds: 6),  // 4:30 pm PST Nov 20 (UTC says Nov 21)
        ].joined(separator: "\n")
        let now = date("2026-11-21T01:00:00.000Z")                    // 5:00 pm PST Nov 20
        let s = TranscriptionHistory.stats(in: content, on: now, calendar: pacific)
        XCTAssertEqual(s, TranscriptionHistory.DayStats(count: 2, words: 30, spokenSeconds: 10))
    }

    func testDayRollsOverAtLocalMidnightNotUTC() {
        let content = [
            line("2026-11-21T07:59:59.000Z", words: 5, seconds: 1),   // 11:59 pm PST Nov 20
            line("2026-11-21T08:00:01.000Z", words: 7, seconds: 2),   // 12:00 am PST Nov 21
            line("2026-11-22T07:59:00.000Z", words: 9, seconds: 3),   // 11:59 pm PST Nov 21
            line("2026-11-22T08:01:00.000Z", words: 99, seconds: 9),  // Nov 22 local
        ].joined(separator: "\n")
        let nov21 = date("2026-11-21T20:00:00.000Z")
        let s = TranscriptionHistory.stats(in: content, on: nov21, calendar: pacific)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.words, 16)
        XCTAssertEqual(s.spokenSeconds, 5, accuracy: 0.001)
    }

    func testEmptyAndMalformedLinesAreSkipped() {
        let now = date("2026-11-20T20:00:00.000Z")
        XCTAssertEqual(TranscriptionHistory.stats(in: "", on: now, calendar: pacific), .init())
        let junk = "not json 2026-11-20\n" + line("2026-11-20T20:00:00.000Z", words: 3, seconds: 1)
        XCTAssertEqual(TranscriptionHistory.stats(in: junk, on: now, calendar: pacific).words, 3)
    }
}
