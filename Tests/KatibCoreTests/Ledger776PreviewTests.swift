import SwiftUI
import XCTest
@testable import KatibCore

/// Renders the popover ledger, the Manage Permissions sheet and the receipt to
/// PNG when KATIB_LEDGER_PREVIEW=<dir> is set (light and dark). No-op
/// otherwise. Sample numbers are the 2026-11-20 mockup day.
@MainActor
final class Ledger776PreviewTests: XCTestCase {
    private func write<V: View>(_ view: V, scheme: ColorScheme, name: String, dir: String) throws {
        let p = Palette776.for(scheme)
        // Backdrop stands in for the desktop behind the popover or window.
        let framed = view.fixedSize().padding(28)
            .background(scheme == .dark ? Color.black : Color(red: 0.80, green: 0.79, blue: 0.75))
            .environment(\.colorScheme, scheme)
        _ = p
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func sampleData(withLast: Bool = true) -> PopoverLedgerData {
        PopoverLedgerData(
            ready: true, statusText: "Ready", dateLabel: "Fri Nov 20",
            figures: LedgerFigures(dictations: 14, words: 1286, spokenSeconds: 582, wpm: 40),
            typingWPM: 40,
            lastText: withLast ? "Sounds good, I'll send the revised deck to Katelin by end of day and loop in Chris on the fund numbers." : nil,
            lastReceipt: withLast ? DictationReceipt(app: "Slack", words: 21, spokenSeconds: 8.2, wpm: 40) : nil,
            lastTime: withLast ? "2:07 PM" : nil,
            hotkeyName: "Right Option", correctionsCount: 212, clipboardBadge: "38")
    }

    func testWritePreviewWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["KATIB_LEDGER_PREVIEW"] else { return }
        let iconPath = ProcessInfo.processInfo.environment["KATIB_ICON"] ?? ""
        let icon = NSImage(contentsOfFile: iconPath)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let p = Palette776.for(scheme)
            let popover = PopoverLedgerView(
                data: sampleData(), actions: PopoverLedgerActions(), appIcon: icon,
                clipboardOpen: .constant(false), banners: { EmptyView() }, clipboardBody: { EmptyView() })
                .background(p.box)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
            try write(popover, scheme: scheme, name: "popover-\(name)", dir: dir)

            let empty = PopoverLedgerView(
                data: sampleData(withLast: false), actions: PopoverLedgerActions(), appIcon: icon,
                clipboardOpen: .constant(false), banners: { EmptyView() }, clipboardBody: { EmptyView() })
                .background(p.box)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
            try write(empty, scheme: scheme, name: "popover-empty-\(name)", dir: dir)

            try write(ManagePermissionsView(appIcon: icon, onClose: nil)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1)),
                      scheme: scheme, name: "sheet-\(name)", dir: dir)

            try write(DictationReceiptCard(
                receipt: DictationReceipt(app: "Slack", words: 21, spokenSeconds: 8.2, wpm: 40), time: "2:07 PM"),
                      scheme: scheme, name: "receipt-\(name)", dir: dir)
        }
    }
}
