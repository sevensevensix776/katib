import AppKit

/// Private pasteboard types Katib writes alongside content so other parts of
/// the app can tell "this was us" and skip it. Lives in KatibCore so both
/// KatibDictation (writes it when pasting a transcription) and KatibClipboard
/// (skips it when polling for history) can reference the same constant.
public enum KatibPasteboard {
    /// Written on any paste originating from Katib (dictation, clipboard
    /// re-paste, annotated screenshot copy). Clipboard history watcher
    /// ignores items carrying this type.
    public static let katibMarkerType = NSPasteboard.PasteboardType("com.sevensevensix.katib.dictated")
}
