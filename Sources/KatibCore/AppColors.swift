import SwiftUI
import AppKit

/// Katib palette. Bronze-on-charcoal comes from the Live Indicator — this file
/// propagates that accent everywhere else so the popover, settings, and
/// corrections editor feel like one app rather than three.
public enum AppColors {
    /// Primary accent. Used for the menu bar status dot, tint on buttons, and
    /// active sheet elements. Warm bronze reads as "scribe's notebook" — the
    /// Katib name is Arabic for "The Scribe" (كاتب).
    public static let bronze = Color(red: 0.78, green: 0.58, blue: 0.32)

    /// AppKit-friendly NSColor mirror for drawing inside NSView subclasses.
    public static let bronzeNSColor = NSColor(red: 0.78, green: 0.58, blue: 0.32, alpha: 1.0)

    /// Slightly lighter bronze for hover / pressed / selected states.
    public static let bronzeHighlight = Color(red: 0.88, green: 0.68, blue: 0.40)

    /// Live-recording red, matches macOS's own screen-recording indicator.
    public static let recording = Color.red

    /// Muted text color that adapts to light/dark mode — prefer over .secondary
    /// for accent copy that should fade but not disappear.
    public static let mutedAccent = Color.primary.opacity(0.55)
}
