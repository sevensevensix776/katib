import SwiftUI
import KatibCore

/// A Mac keyboard with the keys to press lit, so a new user can find
/// "Right Option" or "⇧⌘3" without knowing the names. `held` makes the lit
/// keys glow; the dictation step sets it while Katib is recording, which
/// also proves the hotkey works.
struct KeyboardHint: View {
    let lit: Set<String>
    var held = false

    static func dictation(_ side: AppSettings.HotkeySide) -> Set<String> {
        [side == .rightOption ? "ropt" : "lopt"]
    }
    static let screenshot: Set<String> = ["lshift", "lcmd", "3"]

    private struct Key {
        let id: String
        let label: String
        var sub: String?
        var width: CGFloat = 1
    }

    private static func letters(_ s: String) -> [Key] { s.map { Key(id: String($0).lowercased(), label: String($0)) } }

    // Each row is 14.5 units wide, so the rows line up at both ends.
    private static let rows: [[Key]] = [
        letters("`1234567890-=") + [Key(id: "delete", label: "delete", width: 1.5)],
        [Key(id: "tab", label: "tab", width: 1.5)] + letters("QWERTYUIOP[]\\"),
        [Key(id: "caps", label: "caps lock", width: 1.75)] + letters("ASDFGHJKL;'")
            + [Key(id: "return", label: "return", width: 1.75)],
        [Key(id: "lshift", label: "⇧", sub: "shift", width: 2.25)] + letters("ZXCVBNM,./")
            + [Key(id: "rshift", label: "⇧", sub: "shift", width: 2.25)]
    ]

    private static let bottom: [Key] = [
        Key(id: "fn", label: "fn"),
        Key(id: "lctrl", label: "⌃", sub: "control"),
        Key(id: "lopt", label: "⌥", sub: "option"),
        Key(id: "lcmd", label: "⌘", sub: "command", width: 1.25),
        Key(id: "space", label: "", width: 5),
        Key(id: "rcmd", label: "⌘", sub: "command", width: 1.25),
        Key(id: "ropt", label: "⌥", sub: "option")
    ]

    private let unit: CGFloat = 29
    private let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Self.rows.indices, id: \.self) { i in
                HStack(spacing: gap) { ForEach(Self.rows[i], id: \.id) { key($0) } }
            }
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Self.bottom, id: \.id) { key($0) }
                arrows
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard with the keys to press highlighted")
    }

    private func width(_ units: CGFloat) -> CGFloat { units * (unit + gap) - gap }

    private func key(_ key: Key) -> some View {
        let on = lit.contains(key.id)
        let fill: Color = on ? (held ? AppColors.bronze : AppColors.bronze.opacity(0.8)) : Color.primary.opacity(0.06)
        return VStack(spacing: 0) {
            Text(key.label).font(.system(size: key.label.count > 1 ? 7 : 10))
            if let sub = key.sub { Text(sub).font(.system(size: 6)) }
        }
        .foregroundColor(on ? .white : .secondary)
        .frame(width: width(key.width), height: unit)
        .background(RoundedRectangle(cornerRadius: 5).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? AppColors.bronze : Color.primary.opacity(0.15)))
        .scaleEffect(on && held ? 0.92 : 1)
        .shadow(color: on && held ? AppColors.bronze.opacity(0.6) : .clear, radius: 8)
        .animation(.easeOut(duration: 0.12), value: held)
    }

    private var arrows: some View {
        let half = (unit - gap) / 2
        return HStack(alignment: .bottom, spacing: gap) {
            arrow("◀", half)
            VStack(spacing: gap) { arrow("▲", half); arrow("▼", half) }
            arrow("▶", half)
        }
    }

    private func arrow(_ symbol: String, _ height: CGFloat) -> some View {
        Text(symbol).font(.system(size: 6)).foregroundColor(.secondary)
            .frame(width: unit, height: height)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
    }
}
