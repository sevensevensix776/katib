import SwiftUI

// Direction C: 776 Tape. Centered, receipt-like; dashed perforations, a double rule above the total.
struct Tape<Cc: View>: View {
    let p: P; let w: CGFloat
    @ViewBuilder var c: Cc
    var body: some View {
        c.frame(width: w).background(p.box, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(p.line, lineWidth: 1))
    }
}
func dbl(_ p: P) -> some View { VStack(spacing: 2) { Rule(c: p.rule); Rule(c: p.rule) } }

struct CPopover: View {
    let p: P
    func item(_ a: String, _ b: String) -> some View {
        Leader(p: p) { Text(a).font(sw(12.5)).foregroundColor(p.body) } right: { Text(b).font(sw(12.5)).monospacedDigit().foregroundColor(p.ink) }
    }
    var body: some View {
        Tape(p: p, w: 340) {
            VStack(spacing: 0) {
                Icon(s: 36).padding(.bottom, 8)
                Lbl(t: "Katib · The Scribe", p: p, color: p.ink)
                Lbl(t: "Fri Nov 20 · Ready", p: p, size: 9, color: p.muted).padding(.top, 5).padding(.bottom, 14)
                Rule(c: p.muted, dash: true).padding(.bottom, 12)
                VStack(spacing: 7) { item("Dictations", D.dictations); item("Words", D.words); item("Spoken", D.spoken); item("Typing would take", D.typing) }
                dbl(p).padding(.top, 12).padding(.bottom, 10)
                HStack(alignment: .lastTextBaseline) {
                    Lbl(t: "Time saved", p: p, size: 10.5, color: p.ink); Spacer()
                    (Text(D.saved).foregroundColor(p.ink) + Text(".").foregroundColor(p.purple)).font(sw(30)).tracking(-1.5).monospacedDigit()
                }.padding(.bottom, 12)
                Rule(c: p.muted, dash: true).padding(.bottom, 12)
                Lbl(t: "Last · \(D.lastTime) · \(D.lastApp)", p: p, size: 9).padding(.bottom, 7)
                Text(D.lastText).font(sw(12)).foregroundColor(p.body).multilineTextAlignment(.center).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { Btn(t: "Copy", p: p); Btn(t: "Paste again", p: p); Btn(t: "Undo", p: p) }.padding(.vertical, 12)
                Rule(c: p.muted, dash: true).padding(.bottom, 12)
                VStack(spacing: 7) { item("Clipboard", "38"); item("Corrections", "212") }
                Rule(c: p.muted, dash: true).padding(.vertical, 12)
                Mark776(w: 30).padding(.bottom, 6)
                Lbl(t: "Hold Right Option to dictate · Quit", p: p, size: 8.5, color: p.muted)
            }.padding(20)
        }
    }
}

struct CSheet: View {
    let p: P
    func item(_ n: String, _ why: String, _ st: String, opt: Bool = false, hot: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Leader(p: p) { (Text(n).font(sw(14, .medium)).foregroundColor(p.ink) + Text(opt ? "  optional" : "").font(sw(11)).foregroundColor(p.muted)).fixedSize() } right: {
                Text(st.uppercased()).font(sw(10, .medium)).tracking(2).foregroundColor(hot ? p.purpleText : p.muted) }
            Text(why).font(sw(11.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    var body: some View {
        Tape(p: p, w: 420) {
            VStack(spacing: 0) {
                Icon(s: 56).padding(.bottom, 10)
                Lbl(t: "Katib · Permissions", p: p, color: p.ink).padding(.bottom, 6)
                Text("Drag the icon above into the list in System Settings.").font(sw(12)).foregroundColor(p.muted).padding(.bottom, 16)
                Rule(c: p.muted, dash: true).padding(.bottom, 14)
                VStack(alignment: .leading, spacing: 13) {
                    item("Microphone", "Lets Katib hear you while you hold the key.", "Granted")
                    item("Speech Recognition", "Turns your voice into text on your Mac.", "Granted")
                    item("Accessibility", "Lets Katib see the key and type for you.", "Needs you", hot: true)
                    item("Screen Recording", "For ⇧⌘3 and ⇧⌘4 screenshots.", "Relaunch", opt: true, hot: true)
                }
                dbl(p).padding(.vertical, 14)
                HStack(alignment: .lastTextBaseline) {
                    Lbl(t: "Granted", p: p, size: 10.5, color: p.ink); Spacer()
                    (Text("2 of 4").foregroundColor(p.ink) + Text(".").foregroundColor(p.purple)).font(sw(24)).tracking(-1.2).monospacedDigit()
                }.padding(.bottom, 14)
                HStack(spacing: 8) { Btn(t: "Grant Accessibility…", p: p, fill: true); Btn(t: "Relaunch", p: p) }.padding(.bottom, 14)
                Rule(c: p.muted, dash: true).padding(.bottom, 12)
                Mark776(w: 30)
            }.padding(24)
        }
    }
}

struct CReceipt: View {
    let p: P
    func item(_ a: String, _ b: String, hot: Bool = false) -> some View {
        Leader(p: p) { Text(a).font(sw(12)).foregroundColor(p.body) } right: { Text(b).font(sw(12, hot ? .semibold : .regular)).monospacedDigit().foregroundColor(hot ? p.purpleText : p.ink) }
    }
    var body: some View {
        Tape(p: p, w: 250) {
            VStack(spacing: 7) {
                Lbl(t: "\(D.lastTime) · \(D.lastApp)", p: p, size: 9, color: p.ink)
                Rule(c: p.muted, dash: true)
                item("Words", D.lastWords); item("Spoken", D.lastSpoken); item("Saved", "+\(D.lastSaved)", hot: true)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}
