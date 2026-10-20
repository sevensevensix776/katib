import SwiftUI
import KatibCore

/// The bottom row of a Mac keyboard with the dictation key lit, so a new
/// user can find "Right Option" without knowing its name. `held` lights the
/// key while Katib hears it, which also proves the hotkey works.
struct KeyboardHint: View {
    let side: AppSettings.HotkeySide
    var held = false

    private let unit: CGFloat = 30
    private let gap: CGFloat = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: gap) {
            key("fn")
            key("⌃", "control")
            key("⌥", "option", lit: side == .leftOption)
            key("⌘", "command", width: unit * 1.25)
            key("", width: unit * 4.4)
            key("⌘", "command", width: unit * 1.25)
            key("⌥", "option", lit: side == .rightOption)
            arrows
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold \(side.displayName), next to the space bar")
    }

    private func key(_ symbol: String, _ name: String? = nil, width: CGFloat? = nil, lit: Bool = false) -> some View {
        let fill: Color = lit ? (held ? AppColors.bronze : AppColors.bronze.opacity(0.75)) : Color.primary.opacity(0.06)
        return VStack(spacing: 1) {
            Text(symbol).font(.system(size: 11))
            if let name { Text(name).font(.system(size: 7)) }
        }
        .foregroundColor(lit ? .white : .secondary)
        .frame(width: width ?? unit, height: unit)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(lit ? AppColors.bronze : Color.primary.opacity(0.15)))
        .scaleEffect(lit && held ? 0.94 : 1)
        .shadow(color: lit && held ? AppColors.bronze.opacity(0.6) : .clear, radius: 8)
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
        Text(symbol).font(.system(size: 7)).foregroundColor(.secondary)
            .frame(width: unit * 0.8, height: height)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
    }
}
