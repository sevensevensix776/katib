import XCTest
@testable import KatibCore

final class SettingsPaneTests: XCTestCase {
    func testEveryPaneIsASystemSettingsURL() {
        for pane in SettingsPane.allCases {
            XCTAssertEqual(pane.url.scheme, "x-apple.systempreferences", pane.rawValue)
            XCTAssertFalse(pane.title.isEmpty, pane.rawValue)
        }
    }

    // The URLs verified by hand on macOS 27.0 (26A428). A change here needs
    // the same check again: open it and read the System Settings window title.
    func testPrivacyPanesUseTheMacOS27ExtensionAndAnchor() {
        let privacy = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"
        XCTAssertEqual(SettingsPane.accessibility.url.absoluteString, privacy + "Privacy_Accessibility")
        XCTAssertEqual(SettingsPane.inputMonitoring.url.absoluteString, privacy + "Privacy_ListenEvent")
        XCTAssertEqual(SettingsPane.microphone.url.absoluteString, privacy + "Privacy_Microphone")
        XCTAssertEqual(SettingsPane.speechRecognition.url.absoluteString, privacy + "Privacy_SpeechRecognition")
        XCTAssertEqual(SettingsPane.screenRecording.url.absoluteString, privacy + "Privacy_ScreenCapture")
        XCTAssertEqual(SettingsPane.siri.url.absoluteString,
                       "x-apple.systempreferences:com.apple.Siri-Settings.extension")
    }
}
