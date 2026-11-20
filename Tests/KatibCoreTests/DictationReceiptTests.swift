import XCTest
@testable import KatibCore

final class DictationReceiptTests: XCTestCase {
    func testTimeSavedIsWordsOverSpeedMinusSpoken() {
        // 21 words at 40 wpm = 31.5 s of typing; spoke for 8 s; saved 23.5 s.
        XCTAssertEqual(TimeSaved.typingSeconds(words: 21, wpm: 40), 31.5, accuracy: 0.001)
        XCTAssertEqual(TimeSaved.savedSeconds(words: 21, spokenSeconds: 8, wpm: 40), 23.5, accuracy: 0.001)
        // Faster typist, less saved: 21 words at 80 wpm = 15.75 s.
        XCTAssertEqual(TimeSaved.savedSeconds(words: 21, spokenSeconds: 8, wpm: 80), 7.75, accuracy: 0.001)
    }

    func testTimeSavedNeverGoesNegative() {
        // 2 words held for 10 s would "save" -7 s; show nothing saved instead.
        XCTAssertEqual(TimeSaved.savedSeconds(words: 2, spokenSeconds: 10, wpm: 40), 0)
        XCTAssertEqual(TimeSaved.savedSeconds(words: 0, spokenSeconds: 0, wpm: 40), 0)
        XCTAssertEqual(TimeSaved.typingSeconds(words: 10, wpm: 0), 0, "zero speed must not divide by zero")
    }

    func testClockFormat() {
        XCTAssertEqual(TimeSaved.clock(8), "0:08")
        XCTAssertEqual(TimeSaved.clock(23.5), "0:24")
        XCTAssertEqual(TimeSaved.clock(582), "9:42")
        XCTAssertEqual(TimeSaved.clock(3725), "1:02:05")
        XCTAssertEqual(TimeSaved.clock(-4), "0:00")
    }

    func testReceiptLineMatchesTheMockup() {
        // The 2026-11-20 mockup line: Slack ..... 21 w  0:08  +0:23
        let r = DictationReceipt(app: "Slack", words: 21, spokenSeconds: 8.2, wpm: 40)
        XCTAssertEqual(r.detail, "21 w  0:08")
        XCTAssertEqual(r.saved, "+0:23")
        XCTAssertEqual(r.plain, "Slack ..... 21 w  0:08  +0:23")
    }

    func testLedgerFiguresForTheMockupDay() {
        // 14 dictations, 1,286 words, 9:42 spoken. 1286 / 40 wpm = 32:09 typing; saved 22:27.
        let f = LedgerFigures(dictations: 14, words: 1286, spokenSeconds: 582, wpm: 40)
        XCTAssertEqual(f.wordsText, "1,286")
        XCTAssertEqual(f.spokenText, "9:42")
        XCTAssertEqual(f.typingText, "32:09")
        XCTAssertEqual(f.savedText, "22:27")
    }

    @MainActor
    func testTypingSpeedPersistsAndClamps() {
        let suite = AppSettings.shared._useIsolatedTestStore()
        XCTAssertEqual(AppSettings.shared.typingWPM >= TimeSaved.wpmRange.lowerBound, true)
        AppSettings.shared.typingWPM = 55
        XCTAssertEqual(suite.integer(forKey: "typingWPM"), 55)
        AppSettings.shared.typingWPM = 5000
        XCTAssertEqual(AppSettings.shared.typingWPM, TimeSaved.wpmRange.upperBound)
        AppSettings.shared.typingWPM = 0
        XCTAssertEqual(AppSettings.shared.typingWPM, TimeSaved.wpmRange.lowerBound)
        XCTAssertEqual(suite.integer(forKey: "typingWPM"), TimeSaved.wpmRange.lowerBound)
    }
}
