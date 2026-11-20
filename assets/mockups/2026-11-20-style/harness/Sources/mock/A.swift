import SwiftUI

// Direction A: 776 Ledger (the pick). Pure 776: ink/paper, purple accent, lavender labels,
// ledger rows with dotted leaders. No Katib gold.
struct Surface<C: View>: View {
    let p: P; let w: CGFloat; var radius: CGFloat = 12
    @ViewBuilder var c: C
    var body: some View {
        c.frame(width: w, alignment: .leading)
            .background(p.box, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(p.line, lineWidth: 1))
    }
}

struct APopover: View {
    let p: P
    var body: some View {
        Surface(p: p, w: 360) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Icon(s: 28)
                    Head(t: "Katib", size: 20, p: p)
                    Spacer()
                    HStack(spacing: 6) { Circle().fill(p.purple).frame(width: 6, height: 6); Lbl(t: "Ready", p: p) }
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundColor(p.muted).padding(.leading, 6)
                }.padding(.bottom, 16)
                Rule(c: p.rule)
                HStack { Lbl(t: "Today", p: p); Spacer(); Lbl(t: "Fri Nov 20", p: p, color: p.muted) }.padding(.vertical, 9)
                Rule(c: p.line)
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(D.words).font(sw(46)).tracking(-2.3).monospacedDigit().foregroundColor(p.ink)
                    Text("words dictated").font(sw(13)).foregroundColor(p.muted)
                }.padding(.top, 12).padding(.bottom, 8)
                VStack(spacing: 7) {
                    Leader(p: p) { Text("Dictations").font(sw(13)).foregroundColor(p.body) } right: { Text(D.dictations).font(sw(13, .medium)).monospacedDigit().foregroundColor(p.ink) }
                    Leader(p: p) { Text("Spoken").font(sw(13)).foregroundColor(p.body) } right: { Text(D.spoken).font(sw(13, .medium)).monospacedDigit().foregroundColor(p.ink) }
                    Leader(p: p) { Text("Typing would take").font(sw(13)).foregroundColor(p.body) } right: { Text(D.typing).font(sw(13, .medium)).monospacedDigit().foregroundColor(p.ink) }
                    Leader(p: p) { Text("Time saved").font(sw(13, .medium)).foregroundColor(p.ink) } right: { Text(D.saved).font(sw(15, .semibold)).monospacedDigit().foregroundColor(p.purpleText) }
                }
                Text("Typing counted at 40 words a minute.").font(sw(10.5)).foregroundColor(p.muted).padding(.top, 6).padding(.bottom, 14)
                Rule(c: p.line)
                HStack { Lbl(t: "Last dictation", p: p); Spacer(); Lbl(t: D.lastTime, p: p, color: p.muted) }.padding(.top, 10).padding(.bottom, 8)
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(p.purple).frame(width: 2)
                    Text(D.lastText).font(sw(12.5)).foregroundColor(p.body).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }.fixedSize(horizontal: false, vertical: true)
                Leader(p: p) { Text(D.lastApp).font(sw(11.5)).foregroundColor(p.muted) } right: {
                    (Text("\(D.lastWords) w   \(D.lastSpoken)   ").foregroundColor(p.muted) + Text("+\(D.lastSaved)").foregroundColor(p.purpleText).fontWeight(.medium))
                        .font(sw(11.5)).monospacedDigit()
                }.padding(.top, 9)
                HStack(spacing: 18) {
                    ForEach(["Copy", "Paste again", "Undo"], id: \.self) { s in
                        Lbl(t: s, p: p, color: p.ink).overlay(alignment: .bottom) { Rectangle().fill(p.purple).frame(height: 1).offset(y: 3) }
                    }
                }.padding(.top, 14).padding(.bottom, 16)
                Rule(c: p.line)
                VStack(spacing: 0) {
                    row("Clipboard", "38"); Rule(c: p.line); row("Corrections", "212")
                }
                Rule(c: p.line)
                HStack(spacing: 8) {
                    Mark776(w: 26)
                    Spacer()
                    Lbl(t: "Hold Right Option", p: p, size: 9.5, color: p.muted)
                    Lbl(t: "Quit", p: p, size: 9.5, color: p.ink).padding(.leading, 10)
                }.padding(.top, 12)
            }.padding(18)
        }
    }
    func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a).font(sw(13)).foregroundColor(p.body); Spacer(); Text(b).font(sw(13)).monospacedDigit().foregroundColor(p.muted)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundColor(p.muted) }.padding(.vertical, 9)
    }
}

struct ASheet: View {
    let p: P
    func row(_ n: String, _ why: String, opt: Bool = false, state: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                (Text(n).font(sw(15, .medium)).foregroundColor(p.ink) + Text(opt ? "   OPTIONAL" : "").font(sw(9.5, .medium)).tracking(1.9).foregroundColor(p.muted))
                Spacer()
                switch state {
                case 0: HStack(spacing: 6) { Circle().fill(p.purple).frame(width: 6, height: 6); Lbl(t: "Granted", p: p, color: p.ink) }
                case 1: Btn(t: "Grant…", p: p)
                default: Btn(t: "Relaunch to finish", p: p, fill: true)
                }
            }
            Text(why).font(sw(12)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true).padding(.trailing, 90)
            if state == 2 { Text("Turned it on already? Katib needs a restart to see it.").font(sw(11.5)).foregroundColor(p.purpleText) }
        }.padding(.vertical, 13)
    }
    var body: some View {
        Surface(p: p, w: 460) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Head(t: "Manage permissions", size: 30, p: p)
                    Spacer()
                    Icon(s: 46).onTapGesture {}
                }
                Text("Katib needs four things from macOS. Everything stays on your Mac.").font(sw(13)).foregroundColor(p.muted).padding(.top, 6).padding(.bottom, 18)
                HStack(alignment: .top, spacing: 12) {
                    Rectangle().fill(p.purple).frame(width: 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Lbl(t: "Drag", p: p, color: p.purpleText)
                        Text("Drag the icon above into the list in System Settings. Turn Katib on if it is already there.").font(sw(12.5)).foregroundColor(p.body).fixedSize(horizontal: false, vertical: true)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(.bottom, 18)
                Rule(c: p.rule)
                HStack { Lbl(t: "Permission", p: p); Spacer(); Lbl(t: "Status", p: p) }.padding(.vertical, 9)
                Rule(c: p.line)
                row("Microphone", "Lets Katib hear you while you hold the dictation key.", state: 0); Rule(c: p.line)
                row("Speech Recognition", "Lets Katib turn your voice into text on your Mac. Nothing leaves it.", state: 0); Rule(c: p.line)
                row("Accessibility", "Lets Katib see the dictation key and type your dictation into the app you are using.", state: 1); Rule(c: p.line)
                row("Screen & System Audio Recording", "Lets Katib capture the screen for ⇧⌘3 and ⇧⌘4 screenshots.", opt: true, state: 2)
                Rule(c: p.line)
                HStack { Mark776(w: 26); Spacer(); Lbl(t: "2 of 4 granted", p: p, size: 9.5, color: p.muted) }.padding(.top, 14)
            }.padding(26)
        }
    }
}

struct AReceipt: View {
    let p: P
    var body: some View {
        Surface(p: p, w: 340, radius: 6) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { Mark776(w: 18); Lbl(t: "Pasted", p: p, size: 9, color: p.muted); Spacer(); Lbl(t: D.lastTime, p: p, size: 9, color: p.muted) }
                Leader(p: p) { Text(D.lastApp).font(sw(12.5, .medium)).foregroundColor(p.ink) } right: {
                    (Text("\(D.lastWords) w   \(D.lastSpoken)   ").foregroundColor(p.body) + Text("+\(D.lastSaved)").foregroundColor(p.purpleText).fontWeight(.semibold))
                        .font(sw(12.5)).monospacedDigit()
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}
