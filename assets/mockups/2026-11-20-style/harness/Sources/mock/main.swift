import SwiftUI
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
MainActor.assumeIsolated {
    for dark in [false, true] {
        let p = P.make(dark: dark); let m = dark ? "dark" : "light"
        render(APopover(p: p), dark: dark, to: "\(out)/a-popover-\(m).png")
        render(ASheet(p: p), dark: dark, to: "\(out)/a-sheet-\(m).png")
        render(AReceipt(p: p), dark: dark, to: "\(out)/a-receipt-\(m).png")
        render(BPopover(p: p), dark: dark, to: "\(out)/b-popover-\(m).png")
        render(BSheet(p: p), dark: dark, to: "\(out)/b-sheet-\(m).png")
        render(BReceipt(p: p), dark: dark, to: "\(out)/b-receipt-\(m).png")
        render(CPopover(p: p), dark: dark, to: "\(out)/c-popover-\(m).png")
        render(CSheet(p: p), dark: dark, to: "\(out)/c-sheet-\(m).png")
        render(CReceipt(p: p), dark: dark, to: "\(out)/c-receipt-\(m).png")
    }
}
