import XCTest
@testable import KatibCore

final class LoggerTests: XCTestCase {

    func testSummarizeCountsWords() {
        XCTAssertEqual(Logger.summarize("hello world"), "2 words, 11 chars")
    }

    func testSummarizeCountsUTF16CharsNotBytes() {
        // emoji is 1 grapheme cluster but several bytes — .count uses Character, so 1.
        XCTAssertEqual(Logger.summarize("hi 👋"), "2 words, 4 chars")
    }

    func testSummarizeHandlesEmpty() {
        XCTAssertEqual(Logger.summarize(""), "0 words, 0 chars")
    }

    func testSummarizeHandlesWhitespaceOnly() {
        XCTAssertEqual(Logger.summarize("   "), "0 words, 3 chars")
    }

    func testSummarizeHandlesNewlines() {
        XCTAssertEqual(Logger.summarize("line one\nline two"), "4 words, 17 chars")
    }

    func testSummarizeDoesNotLeakContent() {
        // The exact reason summarize exists: a secret password in must NOT show in out.
        let secret = "hunter2 my_password_123"
        let out = Logger.summarize(secret)
        XCTAssertFalse(out.contains("hunter2"))
        XCTAssertFalse(out.contains("my_password_123"))
    }
}
