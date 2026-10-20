import SwiftUI
import KatibCore
import KatibDictation
import KatibClipboard
import KatibScreenshot

@main
struct KatibApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
