import SwiftUI
import XCTest
@testable import KatibCore

/// Renders the sheet to PNG when KATIB_PERMS_PREVIEW=<dir> is set (light and
/// dark). No-op otherwise. Reads the real permission state of the test host.
@MainActor
final class ManagePermissionsPreviewTests: XCTestCase {
    func testWritePreviewWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["KATIB_PERMS_PREVIEW"] else { return }
        let iconPath = ProcessInfo.processInfo.environment["KATIB_ICON"] ?? ""
        let icon = NSImage(contentsOfFile: iconPath)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = ManagePermissionsView(appIcon: icon, onClose: {})
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let rep = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))!
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("manage-permissions-\(name).png"))
        }
    }
}
