import SwiftUI
import AppKit

/// The 776 look in one file. Every colour and type decision for the popover,
/// the Manage Permissions sheet and the dictation receipt lives here; no
/// other file holds a hex value. Source of truth for the values:
/// experiments/visuals/theme/776.json and docs/STYLE.md. Direction "A, 776
/// Ledger", chosen 2026-11-20 (assets/mockups/2026-11-20-style/).
///
/// Views read the palette from their colour scheme, not from a dynamic
/// NSColor, so a rendered preview in light or dark matches the live app.
public struct Palette776: Sendable {
    /// Page surface behind everything (Ink in dark, Paper in light).
    public let bg: Color
    /// Card surface one step off the page.
    public let box: Color
    public let ink: Color
    /// Running text.
    public let body: Color
    public let muted: Color
    /// Hairline rules and dotted leaders.
    public let line: Color
    /// Heavy rule that opens a table.
    public let rule: Color
    /// The one accent: dots, left rules, underlines, the saved figure's fill.
    public let purple: Color
    /// Purple tuned to read as text on this surface.
    public let purpleText: Color
    /// Small uppercase labels: lavender in dark, muted in light.
    public let label: Color
    /// Not-ready / warning state. System orange, not a brand colour.
    public let warn: Color

    private static func c(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255,
              opacity: alpha)
    }

    public static let dark = Palette776(
        bg: c(0x101110), box: c(0x1a1a19), ink: c(0xe7e6de), body: c(0xc9c8c0), muted: c(0xa6a69e),
        line: c(0xe7e6de, 0.16), rule: c(0xe7e6de, 0.55),
        purple: c(0x776bce), purpleText: c(0xaca4e1), label: c(0xaca4e1), warn: .orange)

    public static let light = Palette776(
        bg: c(0xe7e6de), box: c(0xf4f3ee), ink: c(0x101110), body: c(0x3a3a37), muted: c(0x6f6e68),
        line: c(0x101110, 0.16), rule: c(0x101110, 0.8),
        purple: c(0x776bce), purpleText: c(0x3c3776), label: c(0x6f6e68), warn: .orange)

    public static func `for`(_ scheme: ColorScheme) -> Palette776 { scheme == .dark ? .dark : .light }

    /// Mark colours. The mark is drawn the same in both schemes.
    fileprivate static let markLavender = c(0xaca4e1)
    fileprivate static let markPurple = c(0x776bce)
}

/// Type. Switzer is the 776 face, but its licence (ITF FFL 2.0) does not
/// clearly allow shipping it inside an app that is handed to other people,
/// so Katib uses SF Pro at the same weights and tracking. To switch, change
/// `font` here and nowhere else.
public enum Type776 {
    public static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Small uppercase label, tracking .2em.
public struct Label776: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var size: CGFloat = 10
    var color: Color?
    public init(_ text: String, size: CGFloat = 10, color: Color? = nil) {
        self.text = text; self.size = size; self.color = color
    }
    public var body: some View {
        let p = Palette776.for(scheme)
        Text(text.uppercased())
            .font(Type776.font(size, .medium)).tracking(size * 0.2)
            .foregroundColor(color ?? p.label)
    }
}

/// Headline: tracking -.05em, the final full stop in purple.
public struct Headline776: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let size: CGFloat
    public init(_ text: String, size: CGFloat) { self.text = text; self.size = size }
    public var body: some View {
        let p = Palette776.for(scheme)
        (Text(text).foregroundColor(p.ink) + Text(".").foregroundColor(p.purple))
            .font(Type776.font(size, .medium)).tracking(-0.05 * size)
    }
}

/// Row of dots between a name and its value.
public struct DotLeader776: View {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public var body: some View {
        let p = Palette776.for(scheme)
        GeometryReader { g in
            Path { s in
                s.move(to: CGPoint(x: 0, y: 0.5))
                s.addLine(to: CGPoint(x: g.size.width, y: 0.5))
            }
            .stroke(p.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 3.4]))
        }
        .frame(height: 2)
    }
}

/// `name ........ value`.
public struct LeaderRow776<L: View, R: View>: View {
    let left: L
    let right: R
    public init(@ViewBuilder left: () -> L, @ViewBuilder right: () -> R) {
        self.left = left(); self.right = right()
    }
    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            left
            DotLeader776().alignmentGuide(.lastTextBaseline) { d in d[.bottom] + 3 }
            right
        }
    }
}

/// Hairline (or heavy) horizontal rule.
public struct Rule776: View {
    @Environment(\.colorScheme) private var scheme
    var heavy = false
    public init(heavy: Bool = false) { self.heavy = heavy }
    public var body: some View {
        let p = Palette776.for(scheme)
        Rectangle().fill(heavy ? p.rule : p.line).frame(height: 1)
    }
}

/// The 776 mark: three hexagon-like shapes (page/assets/776-mark.svg).
public struct Mark776: View {
    let width: CGFloat
    public init(width: CGFloat) { self.width = width }
    public var body: some View {
        let k = width / 76.2
        Canvas { ctx, _ in
            func poly(_ pts: [(Double, Double)], _ col: Color) {
                var path = Path()
                path.move(to: CGPoint(x: pts[0].0 * k, y: pts[0].1 * k))
                for q in pts.dropFirst() { path.addLine(to: CGPoint(x: q.0 * k, y: q.1 * k)) }
                path.closeSubpath()
                ctx.fill(path, with: .color(col))
            }
            poly([(64.9626, 0.668), (54.5161, 6.6676), (54.5161, 18.6684), (64.9626, 24.668),
                  (75.4074, 18.6684), (75.4074, 6.6676)], Palette776.markLavender)
            poly([(39.2635, 0.668), (29.833, 5.1894), (27.5049, 15.3438), (34.0335, 23.4828),
                  (44.4951, 23.4845), (51.0221, 15.3438), (48.6939, 5.1894)], Palette776.markPurple)
            poly([(12.5555, 0.668), (3.125, 5.1894), (0.7969, 15.3438), (7.3238, 23.4828),
                  (17.7854, 23.4845), (24.3141, 15.3438), (21.9859, 5.1894)], Palette776.markPurple)
        }
        .frame(width: width, height: width * 25.34 / 76.2)
        .accessibilityHidden(true)
    }
}

/// Outline button, 6pt corners; `filled` is the one purple action on a screen.
public struct Button776Style: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var filled = false
    public init(filled: Bool = false) { self.filled = filled }
    public func makeBody(configuration: Configuration) -> some View {
        let p = Palette776.for(scheme)
        configuration.label
            .font(Type776.font(12, .medium))
            .foregroundColor(filled ? .white : p.ink)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(filled ? p.purple : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(filled ? p.purple : p.rule.opacity(0.6), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Uppercase text action with a purple underline (Copy, Paste again, Undo).
public struct Action776Style: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let p = Palette776.for(scheme)
        configuration.label
            .font(Type776.font(10, .medium)).tracking(2)
            .textCase(.uppercase)
            .foregroundColor(p.ink)
            .overlay(alignment: .bottom) { Rectangle().fill(p.purple).frame(height: 1).offset(y: 3) }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
