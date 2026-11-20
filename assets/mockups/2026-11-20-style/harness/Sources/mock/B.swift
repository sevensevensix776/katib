import SwiftUI

// Direction B: 776 Stat grid. Same system, headline-led, panels and columns instead of ledger rows.
// Keeps one touch of Katib gold: the "time saved" figure and the app icon.
struct BPopover: View {
    let p: P
    func stat(_ l: String, _ v: String, gold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Lbl(t: l, p: p, size: 9)
            Text(v).font(sw(24)).tracking(-1.2).monospacedDigit().foregroundColor(gold ? p.gold : p.ink)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func vr() -> some View { Rectangle().fill(p.line).frame(width: 1) }
    func row(_ a: String, _ b: String) -> some View {
        HStack { Lbl(t: a, p: p, size: 10, color: p.ink); Spacer(); Text(b).font(sw(12.5)).monospacedDigit().foregroundColor(p.muted)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundColor(p.muted) }.padding(.vertical, 11)
    }
    var body: some View {
        Surface(p: p, w: 360) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Icon(s: 22)
                    Lbl(t: "Katib", p: p, color: p.ink)
                    Spacer()
                    HStack(spacing: 6) { Circle().fill(p.purple).frame(width: 6, height: 6); Lbl(t: "Ready", p: p) }
                    Image(systemName: "gearshape").font(.system(size: 12)).foregroundColor(p.muted).padding(.leading, 6)
                }.padding(.bottom, 20)
                Head(t: "\(D.words) words today", size: 32, p: p).padding(.bottom, 16)
                VStack(spacing: 0) {
                    Rule(c: p.rule)
                    HStack(spacing: 14) {
                        stat("Dictations", D.dictations); vr(); stat("Spoken", D.spoken); vr(); stat("Saved", D.saved, gold: true)
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
                    Rule(c: p.line)
                }
                Text("Saved is typing at 40 words a minute, minus the time you spoke.").font(sw(10.5)).foregroundColor(p.muted).padding(.top, 7).padding(.bottom, 16)
                Lbl(t: "Last dictation · \(D.lastTime)", p: p).padding(.bottom, 7)
                Text(D.lastText).font(sw(13)).foregroundColor(p.body).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) {
                    Lbl(t: D.lastApp, p: p, size: 9, color: p.ink); Text("  ·  \(D.lastWords) words  ·  \(D.lastSpoken)  ·  ").font(sw(11)).monospacedDigit().foregroundColor(p.muted)
                    Text("+\(D.lastSaved)").font(sw(11, .semibold)).monospacedDigit().foregroundColor(p.gold)
                }.padding(.top, 8)
                HStack(spacing: 8) { Btn(t: "Copy", p: p); Btn(t: "Paste again", p: p); Btn(t: "Undo", p: p) }.padding(.top, 12).padding(.bottom, 14)
                Rule(c: p.line)
                row("Clipboard", "38"); Rule(c: p.line); row("Corrections", "212"); Rule(c: p.line)
                HStack { Mark776(w: 26); Spacer(); Lbl(t: "Hold Right Option", p: p, size: 9.5, color: p.muted); Lbl(t: "Quit", p: p, size: 9.5, color: p.ink).padding(.leading, 10) }.padding(.top, 12)
            }.padding(18)
        }
    }
}

struct BSheet: View {
    let p: P
    func row(_ sym: String, _ n: String, _ why: String, opt: Bool = false, state: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: sym).font(.system(size: 14)).foregroundColor(p.muted).frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                (Text(n).font(sw(14, .medium)).foregroundColor(p.ink) + Text(opt ? "   OPTIONAL" : "").font(sw(9, .medium)).tracking(1.8).foregroundColor(p.muted))
                Text(why).font(sw(11.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
                if state == 2 { Text("Turned it on already? Katib needs a restart to see it.").font(sw(11)).foregroundColor(p.purpleText).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 6)
            switch state {
            case 0: Text("GRANTED").font(sw(9.5, .medium)).tracking(1.9).foregroundColor(p.purpleText).padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.purple.opacity(0.6), lineWidth: 1))
            case 1: Btn(t: "Grant…", p: p)
            default: Btn(t: "Relaunch", p: p, fill: true)
            }
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }
    var body: some View {
        Surface(p: p, w: 460) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Icon(s: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Lbl(t: "Katib · Setup", p: p)
                        Head(t: "Manage permissions", size: 26, p: p)
                    }
                }.padding(.bottom, 18)
                Text("Drag the icon into the list in System Settings. Turn Katib on if it is already there.").font(sw(12.5)).foregroundColor(p.body)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.purple.opacity(p.dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 14)
                VStack(spacing: 0) {
                    row("mic.fill", "Microphone", "Lets Katib hear you while you hold the dictation key.", state: 0); Rule(c: p.line)
                    row("waveform", "Speech Recognition", "Turns your voice into text on your Mac. Nothing leaves it.", state: 0); Rule(c: p.line)
                    row("keyboard", "Accessibility", "Lets Katib see the dictation key and type into the app you use.", state: 1); Rule(c: p.line)
                    row("rectangle.dashed.badge.record", "Screen Recording", "Lets Katib capture the screen for ⇧⌘3 and ⇧⌘4.", opt: true, state: 2)
                }.overlay(RoundedRectangle(cornerRadius: 6).stroke(p.line, lineWidth: 1))
                HStack { Mark776(w: 26); Spacer(); Lbl(t: "2 of 4 granted", p: p, size: 9.5, color: p.muted) }.padding(.top, 16)
            }.padding(24)
        }
    }
}

struct BReceipt: View {
    let p: P
    func col(_ l: String, _ v: String, gold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) { Lbl(t: l, p: p, size: 8.5); Text(v).font(sw(15, .medium)).tracking(-0.4).monospacedDigit().foregroundColor(gold ? p.gold : p.ink) }
    }
    var body: some View {
        Surface(p: p, w: 340, radius: 6) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) { Lbl(t: "Pasted", p: p, size: 8.5); Text(D.lastApp).font(sw(15, .medium)).tracking(-0.4).foregroundColor(p.ink) }
                Rectangle().fill(p.line).frame(width: 1)
                col("Words", D.lastWords); col("Spoken", D.lastSpoken); col("Saved", "+\(D.lastSaved)", gold: true)
                Spacer(minLength: 0)
            }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}
