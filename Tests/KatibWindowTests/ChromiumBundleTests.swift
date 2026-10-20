import XCTest
@testable import KatibWindow

/// Locks down the Chromium-bundle detection logic that gates the
/// `AXManualAccessibility` kick. Without this kick, Chrome/Edge/Brave/Arc
/// silently return no focused window — regressions here are invisible at
/// build time but obvious the first time a teammate tries ⌃⌥← on Chrome.
final class ChromiumBundleTests: XCTestCase {

    func testDetectsStableChrome() {
        XCTAssertTrue(WindowManager.isChromiumBundle("com.google.Chrome"))
    }

    func testDetectsChromeChannels() {
        XCTAssertTrue(WindowManager.isChromiumBundle("com.google.Chrome.canary"))
        XCTAssertTrue(WindowManager.isChromiumBundle("com.google.Chrome.beta"))
        XCTAssertTrue(WindowManager.isChromiumBundle("com.google.Chrome.dev"))
    }

    func testDetectsEdge() {
        XCTAssertTrue(WindowManager.isChromiumBundle("com.microsoft.edgemac"))
    }

    func testDetectsBrave() {
        XCTAssertTrue(WindowManager.isChromiumBundle("com.brave.Browser"))
    }

    func testDetectsArc() {
        XCTAssertTrue(WindowManager.isChromiumBundle("company.thebrowser.Browser"))
    }

    func testDetectsVivaldiAndOpera() {
        XCTAssertTrue(WindowManager.isChromiumBundle("com.vivaldi.Vivaldi"))
        XCTAssertTrue(WindowManager.isChromiumBundle("com.operasoftware.Opera"))
    }

    func testDoesNotMatchCocoaBrowsersOrEditors() {
        // Safari (WebKit, not Chromium), iTerm2, VS Code, Zed, Xcode — all
        // real apps in Asif's flow. None should get the kick.
        XCTAssertFalse(WindowManager.isChromiumBundle("com.apple.Safari"))
        XCTAssertFalse(WindowManager.isChromiumBundle("com.googlecode.iterm2"))
        XCTAssertFalse(WindowManager.isChromiumBundle("com.microsoft.VSCode"))
        XCTAssertFalse(WindowManager.isChromiumBundle("dev.zed.Zed"))
        XCTAssertFalse(WindowManager.isChromiumBundle("com.apple.dt.Xcode"))
        XCTAssertFalse(WindowManager.isChromiumBundle("com.todesktop.230313mzl4w4u92")) // Cursor
    }

    func testDoesNotMatchEmptyOrRandomStrings() {
        XCTAssertFalse(WindowManager.isChromiumBundle(""))
        XCTAssertFalse(WindowManager.isChromiumBundle("com.google"))
        XCTAssertFalse(WindowManager.isChromiumBundle("Chrome"))
    }
}
