import Foundation
import AppKit
import Carbon.HIToolbox
import KatibCore

/// Types snippets when the user finishes a trigger. Observes keystrokes via
/// a `.listenOnly` CGEvent tap — we don't consume keys, we just watch the
/// stream, and when the tail of the recent-buffer matches a trigger, we:
///
/// 1. Synthesize N backspaces to erase the trigger from the target app
/// 2. Synthesize a Unicode keystroke that types the expansion
///
/// The trigger characters briefly appear before being erased — same visual
/// behaviour as TextExpander / aText / Typinator. Acceptable for v1.
///
/// Safety:
/// - Disabled by default. User opts in.
/// - Never expands while `IsSecureEventInputEnabled()` returns true (password
///   fields, ssh prompts). macOS ensures we don't see those keys either, but
///   belt-and-suspenders.
/// - Buffer is bounded (32 chars) so memory stays flat regardless of session
///   length, and resets on whitespace / navigation keys.
@MainActor
public final class TextExpander {
    public static let shared = TextExpander()

    public var isEnabled: Bool = false {
        didSet { isEnabled ? start() : stop() }
    }

    /// Prefix character the user types to start a trigger (default `;`).
    /// Triggers without this prefix won't auto-expand. Picker still works.
    public var prefixCharacter: Character = ";"

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let bufferCap = 32
    nonisolated(unsafe) private var buffer: String = ""

    private init() {}

    private func start() {
        guard eventTap == nil else { return }
        let mask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let me = Unmanaged<TextExpander>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(type: type, event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.shared.log("TextExpander: failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.shared.log("TextExpander: started")
    }

    private func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        buffer = ""
        Logger.shared.log("TextExpander: stopped")
    }

    // MARK: - Tap handler

    nonisolated private func handle(type: CGEventType, event: CGEvent) {
        guard type == .keyDown else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return
        }
        // Never read secure input — macOS hides it, but explicit refuse is cheap.
        if IsSecureEventInputEnabled() { return }

        // Read the Unicode string for this keyDown. Works even for dead-key
        // composition, emoji pickers, and non-Latin input via any layout.
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else {
            resetBufferOnNavigation(event: event)
            return
        }
        let string = String(utf16CodeUnits: chars, count: length)

        // Any whitespace / control key resets the buffer.
        let isBoundary = string.unicodeScalars.contains { scalar in
            scalar.value < 0x20
                || scalar == Unicode.Scalar(0x7f)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        if isBoundary {
            buffer = ""
            return
        }

        buffer += string
        if buffer.count > bufferCap {
            buffer = String(buffer.suffix(bufferCap))
        }

        Task { @MainActor in self.checkForTrigger() }
    }

    /// Cursor keys / home / end / page up/down: reset buffer since the
    /// insertion point has probably moved.
    nonisolated private func resetBufferOnNavigation(event: CGEvent) {
        let navigationKeyCodes: Set<Int64> = [
            123, 124, 125, 126, // arrow left/right/down/up
            115, 119,           // home / end
            116, 121            // page up / page down
        ]
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if navigationKeyCodes.contains(keyCode) {
            buffer = ""
        }
    }

    // MARK: - Matching + replacement

    private func checkForTrigger() {
        guard isEnabled else { return }
        // Only try matching once the buffer contains the prefix.
        guard let prefixIdx = buffer.lastIndex(of: prefixCharacter) else { return }
        let afterPrefix = String(buffer[buffer.index(after: prefixIdx)...])
        guard !afterPrefix.isEmpty else { return }

        guard let snippet = SnippetStore.shared.match(trigger: afterPrefix) else { return }

        let triggerLength = afterPrefix.count + 1 // +1 for prefix itself
        expand(snippet: snippet, triggerLength: triggerLength)
    }

    private func expand(snippet: Snippet, triggerLength: Int) {
        // Reset buffer first so the synthesized backspaces don't re-trigger us.
        buffer = ""

        // Delete the trigger characters.
        for _ in 0..<triggerLength {
            sendKey(code: UInt16(kVK_Delete))
        }

        // Type the expansion. keyboardSetUnicodeString lets us inject
        // arbitrary Unicode without going through the pasteboard — faster
        // and leaves the user's clipboard intact.
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
        let utf16 = Array(snippet.content.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        event.post(tap: .cghidEventTap)

        SnippetStore.shared.recordUsage(of: snippet.id)
        Logger.shared.log("TextExpander: expanded \(snippet.name)")
    }

    private func sendKey(code: UInt16) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
