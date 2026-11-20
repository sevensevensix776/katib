import SwiftUI
import AppKit

// 776 system, from experiments/visuals/theme/776.json and docs/STYLE.md.
struct P {
    let dark: Bool
    let bg, box, ink, body, muted, line, rule, purple, purpleText, label, gold: Color
    static func make(dark: Bool) -> P {
        func c(_ h: UInt32, _ a: Double = 1) -> Color {
            Color(.sRGB, red: Double((h >> 16) & 255) / 255, green: Double((h >> 8) & 255) / 255, blue: Double(h & 255) / 255, opacity: a)
        }
        if dark {
            return P(dark: true, bg: c(0x101110), box: c(0x1a1a19), ink: c(0xe7e6de), body: c(0xc9c8c0), muted: c(0xa6a69e),
                     line: c(0xe7e6de, 0.16), rule: c(0xe7e6de, 0.55), purple: c(0x776bce), purpleText: c(0xaca4e1), label: c(0xaca4e1), gold: c(0xc79452))
        }
        return P(dark: false, bg: c(0xe7e6de), box: c(0xf4f3ee), ink: c(0x101110), body: c(0x3a3a37), muted: c(0x6f6e68),
                 line: c(0x101110, 0.16), rule: c(0x101110, 0.8), purple: c(0x776bce), purpleText: c(0x3c3776), label: c(0x6f6e68), gold: c(0x8a5f22))
    }
}

func sw(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
    let n = w == .semibold ? "Switzer-Semibold" : (w == .medium ? "Switzer-Medium" : "Switzer-Regular")
    return .custom(n, size: size)
}

struct Lbl: View {
    let t: String; let p: P; var size: CGFloat = 10; var color: Color? = nil
    var body: some View {
        Text(t.uppercased()).font(sw(size, .medium)).tracking(size * 0.2).foregroundColor(color ?? p.label)
    }
}

/// Headline: tracking -.05em, final full stop in the accent.
struct Head: View {
    let t: String; let size: CGFloat; let p: P; var stop: Color? = nil
    var body: some View {
        (Text(t).foregroundColor(p.ink) + Text(".").foregroundColor(stop ?? p.purple))
            .font(sw(size)).tracking(-0.05 * size)
    }
}

struct Dots: View {
    let p: P
    var body: some View {
        GeometryReader { g in
            Path { s in s.move(to: CGPoint(x: 0, y: 0.5)); s.addLine(to: CGPoint(x: g.size.width, y: 0.5)) }
                .stroke(p.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 3.4]))
        }.frame(height: 2)
    }
}

/// Dotted-leader line: name ........ value.
struct Leader<L: View, R: View>: View {
    let p: P
    @ViewBuilder var left: L
    @ViewBuilder var right: R
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            left
            Dots(p: p).alignmentGuide(.lastTextBaseline) { d in d[.bottom] + 3 }
            right
        }
    }
}

struct Rule: View {
    let c: Color; var h: CGFloat = 1; var dash: Bool = false
    var body: some View {
        if dash {
            Path { s in s.move(to: .zero); s.addLine(to: CGPoint(x: 2000, y: 0)) }
                .stroke(c, style: StrokeStyle(lineWidth: h, dash: [4, 3])).frame(height: h).clipped()
        } else { Rectangle().fill(c).frame(height: h) }
    }
}

/// The 776 mark (three shapes), from page/assets/776-mark.svg.
struct Mark776: View {
    let w: CGFloat
    var body: some View {
        let k = w / 76.2
        Canvas { ctx, _ in
            func poly(_ pts: [(Double, Double)], _ col: Color) {
                var p = Path(); p.move(to: CGPoint(x: pts[0].0 * k, y: pts[0].1 * k))
                for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0 * k, y: q.1 * k)) }
                p.closeSubpath(); ctx.fill(p, with: .color(col))
            }
            let lav = Color(red: 0xac / 255, green: 0xa4 / 255, blue: 0xe1 / 255), pur = Color(red: 0x77 / 255, green: 0x6b / 255, blue: 0xce / 255)
            poly([(64.9626, 0.668), (54.5161, 6.6676), (54.5161, 18.6684), (64.9626, 24.668), (75.4074, 18.6684), (75.4074, 6.6676)], lav)
            poly([(39.2635, 0.668), (29.833, 5.1894), (27.5049, 15.3438), (34.0335, 23.4828), (44.4951, 23.4845), (51.0221, 15.3438), (48.6939, 5.1894)], pur)
            poly([(12.5555, 0.668), (3.125, 5.1894), (0.7969, 15.3438), (7.3238, 23.4828), (17.7854, 23.4845), (24.3141, 15.3438), (21.9859, 5.1894)], pur)
        }.frame(width: w, height: w * 25.34 / 76.2)
    }
}

struct Btn: View {
    let t: String; let p: P; var fill = false; var gold = false
    var body: some View {
        Text(t).font(sw(12, .medium))
            .foregroundColor(fill ? Color.white : p.ink)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(fill ? p.purple : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(fill ? p.purple : p.rule.opacity(0.6), lineWidth: 1))
    }
}

let appIcon: NSImage = {
    let path = ProcessInfo.processInfo.environment["KATIB_ICON"] ?? ""
    return NSImage(contentsOfFile: path) ?? NSImage()
}()

struct Icon: View {
    let s: CGFloat
    var body: some View { Image(nsImage: appIcon).resizable().frame(width: s, height: s) }
}

// Sample day (one real-shaped instance). Typing assumed at 40 wpm.
enum D {
    static let dictations = "14", words = "1,286", spoken = "9:42", typing = "32:09", saved = "22:27"
    static let lastText = "Sounds good, I'll send the revised deck to Katelin by end of day and loop in Chris on the fund numbers."
    static let lastApp = "Slack", lastWords = "21", lastSpoken = "0:08", lastSaved = "0:23", lastTime = "14:07"
}

@MainActor func render<V: View>(_ v: V, dark: Bool, pad: CGFloat = 28, to path: String) {
    let p = P.make(dark: dark)
    let backdrop = dark ? Color.black : Color(red: 0.80, green: 0.79, blue: 0.75)
    let framed = v.fixedSize().padding(pad).background(backdrop).environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: framed); r.scale = 2
    guard let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
          let png = rep.representation(using: .png, properties: [:]) else { print("FAIL \(path)"); return }
    try? png.write(to: URL(fileURLWithPath: path)); _ = p
}
