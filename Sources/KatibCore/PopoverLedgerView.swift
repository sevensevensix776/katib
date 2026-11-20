import SwiftUI
import AppKit

/// What the popover's ledger shows. Plain values, so the view renders the same
/// in the app and in the preview test.
public struct PopoverLedgerData {
    public var ready: Bool
    public var statusText: String
    public var dateLabel: String
    public var figures: LedgerFigures
    public var typingWPM: Int
    public var lastText: String?
    public var lastReceipt: DictationReceipt?
    public var lastTime: String?
    public var hotkeyName: String
    public var correctionsCount: Int
    public var clipboardBadge: String

    public init(ready: Bool, statusText: String, dateLabel: String, figures: LedgerFigures, typingWPM: Int,
                lastText: String?, lastReceipt: DictationReceipt?, lastTime: String?,
                hotkeyName: String, correctionsCount: Int, clipboardBadge: String) {
        self.ready = ready; self.statusText = statusText; self.dateLabel = dateLabel
        self.figures = figures; self.typingWPM = typingWPM
        self.lastText = lastText; self.lastReceipt = lastReceipt; self.lastTime = lastTime
        self.hotkeyName = hotkeyName; self.correctionsCount = correctionsCount
        self.clipboardBadge = clipboardBadge
    }

    /// "Fri Nov 20", in the person's locale and time zone.
    public static func dateLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: date)
    }

    public static func timeLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }
}

public struct PopoverLedgerActions {
    public var openSettings: () -> Void
    public var openCorrections: () -> Void
    public var copyLast: () -> Void
    public var pasteAgain: () -> Void
    public var undo: () -> Void
    public var quit: () -> Void
    public init(openSettings: @escaping () -> Void = {}, openCorrections: @escaping () -> Void = {},
                copyLast: @escaping () -> Void = {}, pasteAgain: @escaping () -> Void = {},
                undo: @escaping () -> Void = {}, quit: @escaping () -> Void = {}) {
        self.openSettings = openSettings; self.openCorrections = openCorrections
        self.copyLast = copyLast; self.pasteAgain = pasteAgain; self.undo = undo; self.quit = quit
    }
}

/// Popover body, direction A "776 Ledger": today's words large, dotted-leader
/// rows, the last dictation with a purple rule, the 776 mark in the footer.
/// Banners (update, permissions) and the clipboard list are slots, because
/// they depend on live managers that live in the app target.
public struct PopoverLedgerView<Banners: View, ClipboardBody: View>: View {
    @Environment(\.colorScheme) private var scheme
    let data: PopoverLedgerData
    let actions: PopoverLedgerActions
    let appIcon: NSImage
    @Binding var clipboardOpen: Bool
    let copied: Bool
    let banners: Banners
    let clipboardBody: ClipboardBody

    public init(data: PopoverLedgerData, actions: PopoverLedgerActions, appIcon: NSImage? = nil,
                clipboardOpen: Binding<Bool>, copied: Bool = false,
                @ViewBuilder banners: () -> Banners, @ViewBuilder clipboardBody: () -> ClipboardBody) {
        self.data = data; self.actions = actions
        self.appIcon = appIcon ?? NSApp?.applicationIconImage ?? NSImage()
        self._clipboardOpen = clipboardOpen
        self.copied = copied
        self.banners = banners(); self.clipboardBody = clipboardBody()
    }

    private var p: Palette776 { .for(scheme) }
    private func value(_ s: String, weight: Font.Weight = .medium) -> some View {
        Text(s).font(Type776.font(13, weight)).monospacedDigit().foregroundColor(p.ink)
    }
    private func name(_ s: String) -> some View {
        Text(s).font(Type776.font(13)).foregroundColor(p.body)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 16)
            banners
            Rule776(heavy: true)
            HStack { Label776("Today"); Spacer(); Label776(data.dateLabel, color: p.muted) }.padding(.vertical, 9)
            Rule776()
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(data.figures.wordsText)
                    .font(Type776.font(46)).tracking(-2.3).monospacedDigit().foregroundColor(p.ink)
                Text("words dictated").font(Type776.font(13)).foregroundColor(p.muted)
            }
            .padding(.top, 12).padding(.bottom, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(data.figures.wordsText) words dictated today")
            VStack(spacing: 7) {
                LeaderRow776 { name("Dictations") } right: { value("\(data.figures.dictations)") }
                LeaderRow776 { name("Spoken") } right: { value(data.figures.spokenText) }
                LeaderRow776 { name("Typing would take") } right: { value(data.figures.typingText) }
                LeaderRow776 {
                    Text("Time saved").font(Type776.font(13, .medium)).foregroundColor(p.ink)
                } right: {
                    Text(data.figures.savedText).font(Type776.font(15, .semibold)).monospacedDigit().foregroundColor(p.purpleText)
                }
            }
            Text("Typing counted at \(data.typingWPM) words a minute.")
                .font(Type776.font(10.5)).foregroundColor(p.muted)
                .padding(.top, 6).padding(.bottom, 14)
            Rule776()
            lastDictation
            Rule776()
            clipboardRow
            if clipboardOpen { clipboardBody.padding(.bottom, 10) }
            Rule776()
            Button(action: actions.openCorrections) {
                HStack {
                    name("Corrections"); Spacer()
                    Text("\(data.correctionsCount)").font(Type776.font(13)).monospacedDigit().foregroundColor(p.muted)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundColor(p.muted)
                }
                .padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit corrections. \(data.correctionsCount) total.")
            Rule776()
            footer
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: appIcon).resizable().frame(width: 28, height: 28)
            Headline776("Katib", size: 20)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(data.ready ? p.purple : p.warn).frame(width: 6, height: 6)
                Label776(data.statusText)
            }
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundColor(p.muted)
            }
            .buttonStyle(.plain).padding(.leading, 6)
            .help("Settings")
            .accessibilityLabel("Open Katib settings")
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    @ViewBuilder private var lastDictation: some View {
        HStack {
            Label776("Last dictation"); Spacer()
            if let t = data.lastTime { Label776(t, color: p.muted) }
        }
        .padding(.top, 10).padding(.bottom, 8)
        if let text = data.lastText {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(p.purple).frame(width: 2)
                Text(text).font(Type776.font(12.5)).foregroundColor(p.body)
                    .lineSpacing(2).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let r = data.lastReceipt {
                DictationReceiptLine(r, size: 11.5).padding(.top, 9)
            }
            HStack(spacing: 18) {
                Button(copied ? "Copied" : "Copy", action: actions.copyLast)
                Button("Paste again", action: actions.pasteAgain)
                Button("Undo", action: actions.undo)
            }
            .buttonStyle(Action776Style())
            .padding(.top, 14).padding(.bottom, 16)
        } else {
            Text("Hold \(data.hotkeyName) anywhere, speak, release. Double-tap to re-paste.")
                .font(Type776.font(12.5)).foregroundColor(p.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
        }
    }

    private var clipboardRow: some View {
        Button { clipboardOpen.toggle() } label: {
            HStack {
                name("Clipboard"); Spacer()
                Text(data.clipboardBadge).font(Type776.font(13)).monospacedDigit().foregroundColor(p.muted)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundColor(p.muted)
                    .rotationEffect(.degrees(clipboardOpen ? 90 : 0))
            }
            .padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Mark776(width: 26)
            Spacer()
            Label776("Hold \(data.hotkeyName)", size: 9.5, color: p.muted)
            Button(action: actions.quit) { Label776("Quit", size: 9.5, color: p.ink) }
                .buttonStyle(.plain).padding(.leading, 10)
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit Katib")
        }
        .padding(.top, 12)
    }
}
