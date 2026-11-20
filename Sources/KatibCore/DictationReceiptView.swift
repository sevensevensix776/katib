import SwiftUI

/// `Slack ........ 21 w  0:08  +0:23` as a ledger line. `onDark` pins the
/// dark palette for the dictation HUD, which is always dark.
public struct DictationReceiptLine: View {
    @Environment(\.colorScheme) private var scheme
    let receipt: DictationReceipt
    var size: CGFloat = 12.5
    var onDark = false
    public init(_ receipt: DictationReceipt, size: CGFloat = 12.5, onDark: Bool = false) {
        self.receipt = receipt; self.size = size; self.onDark = onDark
    }
    public var body: some View {
        let p = Palette776.for(onDark ? .dark : scheme)
        LeaderRow776 {
            Text(receipt.app).font(Type776.font(size, .medium)).foregroundColor(p.ink)
        } right: {
            (Text(receipt.detail + "  ").foregroundColor(p.body)
                + Text(receipt.saved).foregroundColor(p.purpleText).fontWeight(.semibold))
                .font(Type776.font(size)).monospacedDigit()
        }
        .environment(\.colorScheme, onDark ? .dark : scheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(receipt.app), \(receipt.words) words, \(TimeSaved.clock(receipt.spokenSeconds)) spoken, \(receipt.saved) saved")
    }
}

/// The small card that shows the receipt after a paste.
public struct DictationReceiptCard: View {
    @Environment(\.colorScheme) private var scheme
    let receipt: DictationReceipt
    let time: String
    public init(receipt: DictationReceipt, time: String) { self.receipt = receipt; self.time = time }
    public var body: some View {
        let p = Palette776.for(scheme)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Mark776(width: 18)
                Label776("Pasted", size: 9, color: p.muted)
                Spacer()
                Label776(time, size: 9, color: p.muted)
            }
            DictationReceiptLine(receipt)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 340)
        .background(p.box, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.line, lineWidth: 1))
    }
}
