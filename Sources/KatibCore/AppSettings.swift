import Foundation
import SwiftUI
import ServiceManagement

/// User preferences stored in UserDefaults. Feature modules observe this
/// (via `@Published` / `objectWillChange`) rather than being poked from
/// `didSet` — that keeps KatibCore free of dependencies on any feature
/// module and avoids circular imports.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    // `var` (not `let`) so `_useIsolatedTestStore()` can redirect to an
    // in-memory suite during tests. Same risk pattern as
    // ClipboardManager / FrecencyStore — without isolation, test setUp
    // mutating AppSettings.shared.* writes to the user's real defaults.
    private var defaults: UserDefaults = .standard

    private enum Keys {
        static let hotkeySide = "hotkeySide"
        static let playFeedbackSounds = "playFeedbackSounds"
        static let showLiveIndicator = "showLiveIndicator"
        static let checkForUpdates = "checkForUpdates"
        // Old name kept so existing installs keep their choice.
        static let syncPluginDictionaries = "teamDictionaryEnabled"
        static let debugTranscripts = "debugTranscripts"
        static let codeModeAppPattern = "codeModeAppPattern"
        static let saveDictationsToClipboard = "saveDictationsToClipboard"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let aiPolishEnabled = "aiPolishEnabled"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardCapacity = "clipboardCapacity"
        static let clipboardRetention = "clipboardRetention"
        static let clipboardPlainTextPaste = "clipboardPlainTextPaste"
        static let screenshotEnabled = "screenshotEnabled"
        static let screenshotSaveLocation = "screenshotSaveLocation"
        static let screenshotAutoCopy = "screenshotAutoCopy"
        static let screenshotAutoSave = "screenshotAutoSave"
        static let screenshotSkipEditor = "screenshotSkipEditor"
        static let screenshotRevealInFinder = "screenshotRevealInFinder"
        static let screenshotSubfolderName = "screenshotSubfolderName"
        static let clipboardHotkeyKeyCode = "clipboardHotkeyKeyCode"
        static let clipboardHotkeyModifiers = "clipboardHotkeyModifiers"
        static let screenshotQuickHotkeyKeyCode = "screenshotQuickHotkeyKeyCode"
        static let screenshotQuickHotkeyModifiers = "screenshotQuickHotkeyModifiers"
        static let screenshotAnnotateHotkeyKeyCode = "screenshotAnnotateHotkeyKeyCode"
        static let screenshotAnnotateHotkeyModifiers = "screenshotAnnotateHotkeyModifiers"
        static let snippetExpansionEnabled = "snippetExpansionEnabled"
        static let snippetHotkeyKeyCode = "snippetHotkeyKeyCode"
        static let snippetHotkeyModifiers = "snippetHotkeyModifiers"
        static let snippetPrefixCharacter = "snippetPrefixCharacter"
        static let windowBindings = "windowBindings"
        static let windowDragSnapEnabled = "windowDragSnapEnabled"
        static let windowSnapDelay = "windowSnapDelay"
        static let windowSnapPreview = "windowSnapPreview"
        static let windowCornerSnap = "windowCornerSnap"
        static let windowMultiDisplayBorder = "windowMultiDisplayBorder"
        static let windowGap = "windowGap"
        static let windowSnapExcludedBundleIDs = "windowSnapExcludedBundleIDs"
        static let aiCleanupPrompt = "aiCleanupPrompt"
        static let aiCleanupAppProfiles = "aiCleanupAppProfiles"
    }

    /// Ship defaults the AI cleanup pass starts from. Exposed as a static
    /// property so the Settings "Reset to default" button can write it back.
    public static let defaultAICleanupPrompt = """
    You clean up speech-to-text transcriptions. Given a transcription, return ONLY the cleaned text with:
    - Correct punctuation and capitalization.
    - Redundant restarts and stutters removed ("I think I think we should" -> "I think we should").
    - "Um", "uh", "like", and other fillers removed.
    - Meaning unchanged. Tone unchanged. Do not paraphrase. Do not shorten.
    - Preserve technical terms and proper nouns exactly as written — they've already been corrected.
    - Do not add any new content, explanations, or quotation marks.
    Respond with the cleaned text only, nothing else.
    """

    /// Ship defaults for the per-app profile map. `bundleIDRegex → prompt tail`.
    /// Matched as Swift Regex (case-insensitive, substring). First match wins.
    public static let defaultAICleanupAppProfiles: [String: String] = [
        "cursor|vscode|Xcode|iTerm": "Output should read like a concise code comment — technical, no filler.",
        "Slack|Messages|Discord|WhatsApp": "Output should read like a casual chat message — conversational, short.",
        "Mail|Gmail|Outlook|Spark": "Output should read like a professional email body — complete sentences, courteous.",
        "Notion|Obsidian|Craft|Bear": "Output should read like a note — clear prose, minimal filler."
    ]

    // MARK: - Enums

    public enum HotkeySide: String, CaseIterable, Identifiable {
        case rightOption
        case leftOption
        public var id: String { rawValue }
        public var keyCode: Int64 {
            switch self {
            case .leftOption: return 58
            case .rightOption: return 61
            }
        }
        public var displayName: String {
            switch self {
            case .leftOption: return "Left Option"
            case .rightOption: return "Right Option"
            }
        }
    }

    /// How long the clipboard keeps unpinned items before evicting. Pinned
    /// items are never evicted by age. `unlimited` means no time-based
    /// eviction — the only bound is the count cap.
    public enum ClipboardRetention: String, CaseIterable, Identifiable {
        case threeMonths
        case sixMonths
        case unlimited
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .threeMonths: return "Last 3 months"
            case .sixMonths: return "Last 6 months"
            case .unlimited: return "Unlimited"
            }
        }
        /// Returns 0 for unlimited — ClipboardManager treats 0 as "no eviction".
        public var seconds: TimeInterval {
            switch self {
            case .threeMonths: return 90 * 24 * 3600
            case .sixMonths: return 180 * 24 * 3600
            case .unlimited: return 0
            }
        }
    }

    public enum ScreenshotSaveLocation: String, CaseIterable, Identifiable {
        case desktop
        case downloads
        case pictures
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .desktop: return "Desktop"
            case .downloads: return "Downloads"
            case .pictures: return "Pictures"
            }
        }
    }

    // MARK: - Dictation

    @Published public var hotkeySide: HotkeySide {
        didSet {
            defaults.set(hotkeySide.rawValue, forKey: Keys.hotkeySide)
            NotificationCenter.default.post(name: .katibHotkeyChanged, object: nil)
        }
    }

    @Published public var playFeedbackSounds: Bool {
        didSet { defaults.set(playFeedbackSounds, forKey: Keys.playFeedbackSounds) }
    }

    @Published public var showLiveIndicator: Bool {
        didSet { defaults.set(showLiveIndicator, forKey: Keys.showLiveIndicator) }
    }

    /// Plugins whose dictionary names a `syncURL` re-fetch it in the
    /// background (throttled 6h). Off = the copy on disk only.
    @Published public var syncPluginDictionaries: Bool {
        didSet { defaults.set(syncPluginDictionaries, forKey: Keys.syncPluginDictionaries) }
    }

    /// When on, Katib writes the full transcript text at each pipeline
    /// stage (raw → corrected → polished) to `~/Library/Logs/Katib/katib.log`.
    /// OFF by default — the setting exists for local debugging only. Stays
    /// on-disk; never sent anywhere.
    @Published public var debugTranscripts: Bool {
        didSet { defaults.set(debugTranscripts, forKey: Keys.debugTranscripts) }
    }

    /// Bundle-ID regex for apps that should get "code mode" — phonetic
    /// collapse of words like "dash" / "slash" / "dot" into punctuation
    /// when sandwiched between identifier tokens. Empty string disables
    /// code mode everywhere.
    @Published public var codeModeAppPattern: String {
        didSet { defaults.set(codeModeAppPattern, forKey: Keys.codeModeAppPattern) }
    }

    public static let defaultCodeModeAppPattern = "Cursor|VSCode|Code|Xcode|iTerm|Terminal|Sublime|Zed|ghostty|warp"

    /// Append every completed dictation to clipboard history so the user
    /// can re-paste it later. Default ON — matches how Alfred/Raycast
    /// handle their own dictation flows. Off disables the append;
    /// clipboard history will still never capture mid-paste flashes
    /// because OutputManager marks the pasteboard with our private type.
    @Published public var saveDictationsToClipboard: Bool {
        didSet { defaults.set(saveDictationsToClipboard, forKey: Keys.saveDictationsToClipboard) }
    }

    @Published public var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Keys.hasSeenWelcome) }
    }

    @Published public var aiPolishEnabled: Bool {
        didSet { defaults.set(aiPolishEnabled, forKey: Keys.aiPolishEnabled) }
    }

    // MARK: - App-level

    @Published public var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Keys.checkForUpdates) }
    }

    // MARK: - Clipboard

    /// Feature toggle. KatibClipboard observes this — AppSettings does NOT
    /// reach into the manager directly so the module stays dependency-free.
    @Published public var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Keys.clipboardEnabled) }
    }

    @Published public var clipboardCapacity: Int {
        didSet { defaults.set(clipboardCapacity, forKey: Keys.clipboardCapacity) }
    }

    @Published public var clipboardRetention: ClipboardRetention {
        didSet { defaults.set(clipboardRetention.rawValue, forKey: Keys.clipboardRetention) }
    }

    @Published public var clipboardPlainTextPaste: Bool {
        didSet { defaults.set(clipboardPlainTextPaste, forKey: Keys.clipboardPlainTextPaste) }
    }

    // MARK: - Screenshot

    @Published public var screenshotEnabled: Bool {
        didSet { defaults.set(screenshotEnabled, forKey: Keys.screenshotEnabled) }
    }

    @Published public var screenshotSaveLocation: ScreenshotSaveLocation {
        didSet { defaults.set(screenshotSaveLocation.rawValue, forKey: Keys.screenshotSaveLocation) }
    }

    @Published public var screenshotAutoCopy: Bool {
        didSet { defaults.set(screenshotAutoCopy, forKey: Keys.screenshotAutoCopy) }
    }

    @Published public var screenshotAutoSave: Bool {
        didSet { defaults.set(screenshotAutoSave, forKey: Keys.screenshotAutoSave) }
    }

    @Published public var screenshotSkipEditor: Bool {
        didSet { defaults.set(screenshotSkipEditor, forKey: Keys.screenshotSkipEditor) }
    }

    @Published public var screenshotRevealInFinder: Bool {
        didSet { defaults.set(screenshotRevealInFinder, forKey: Keys.screenshotRevealInFinder) }
    }

    /// Folder name nested under the chosen save location (Desktop/Downloads/
    /// Pictures). Created on first save if missing. Empty string = save
    /// directly into the parent folder, no subfolder.
    @Published public var screenshotSubfolderName: String {
        didSet { defaults.set(screenshotSubfolderName, forKey: Keys.screenshotSubfolderName) }
    }

    // MARK: - Clipboard global hotkey

    /// Carbon keyCode (e.g. 9 = V). Used with `clipboardHotkeyModifiers`.
    @Published public var clipboardHotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(clipboardHotkeyKeyCode), forKey: Keys.clipboardHotkeyKeyCode) }
    }

    /// Carbon modifier flags (e.g. cmdKey | optionKey = 0x900 + 0x800).
    /// Default: Option+Cmd (Alfred's convention, avoids collision with paste).
    @Published public var clipboardHotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(clipboardHotkeyModifiers), forKey: Keys.clipboardHotkeyModifiers) }
    }

    // MARK: - Screenshot global hotkeys

    /// Quick capture (skip annotation editor → straight to clipboard).
    /// Default 20 = "3". Combined with `screenshotQuickHotkeyModifiers`
    /// defaults to ⇧⌘3 — deliberately *overrides* Apple's full-screen
    /// screenshot shortcut by registering earlier in the event chain via
    /// `HotkeyTapRouter`. Carbon couldn't do this.
    @Published public var screenshotQuickHotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(screenshotQuickHotkeyKeyCode), forKey: Keys.screenshotQuickHotkeyKeyCode) }
    }

    /// Default: ⇧⌘ (shiftKey | cmdKey = 0x300).
    @Published public var screenshotQuickHotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(screenshotQuickHotkeyModifiers), forKey: Keys.screenshotQuickHotkeyModifiers) }
    }

    /// Annotate capture (opens the annotation editor after region select).
    /// Default 21 = "4". Combined with `screenshotAnnotateHotkeyModifiers`
    /// defaults to ⇧⌘4.
    @Published public var screenshotAnnotateHotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(screenshotAnnotateHotkeyKeyCode), forKey: Keys.screenshotAnnotateHotkeyKeyCode) }
    }

    /// Default: ⇧⌘ (shiftKey | cmdKey = 0x300).
    @Published public var screenshotAnnotateHotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(screenshotAnnotateHotkeyModifiers), forKey: Keys.screenshotAnnotateHotkeyModifiers) }
    }

    // MARK: - Snippets + text expansion

    /// When on, typing `<prefix><trigger>` auto-expands via TextExpander.
    /// Off by default — opt-in since it taps all keystrokes.
    @Published public var snippetExpansionEnabled: Bool {
        didSet { defaults.set(snippetExpansionEnabled, forKey: Keys.snippetExpansionEnabled) }
    }

    /// Carbon keyCode for the snippet picker hotkey. Default 49 = Space.
    @Published public var snippetHotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(snippetHotkeyKeyCode), forKey: Keys.snippetHotkeyKeyCode) }
    }

    /// Default: Control+Cmd (avoids collision with Spotlight ⌘Space and the
    /// clipboard picker ⌥⌘V).
    @Published public var snippetHotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(snippetHotkeyModifiers), forKey: Keys.snippetHotkeyModifiers) }
    }

    /// Single-character prefix the user types before a trigger (default `;`).
    /// If empty, the expander is effectively disabled — no prefix means any
    /// word boundary could be a trigger, which is too ambiguous.
    @Published public var snippetPrefixCharacter: String {
        didSet { defaults.set(snippetPrefixCharacter, forKey: Keys.snippetPrefixCharacter) }
    }

    // MARK: - Window manager

    /// Per-action window bindings. Keys are `WindowAction.rawValue`, values
    /// are two UInt32 ints: `[keyCode, modifiers]`. Persisted as JSON.
    @Published public var windowBindings: [String: [UInt32]] {
        didSet {
            if let data = try? JSONEncoder().encode(windowBindings),
               let str = String(data: data, encoding: .utf8) {
                defaults.set(str, forKey: Keys.windowBindings)
            }
        }
    }

    @Published public var windowDragSnapEnabled: Bool {
        didSet { defaults.set(windowDragSnapEnabled, forKey: Keys.windowDragSnapEnabled) }
    }

    /// Seconds the pointer has to linger at an edge before the preview
    /// appears. Moom's default: 0.2. 0 = fire instantly.
    @Published public var windowSnapDelay: Double {
        didSet { defaults.set(windowSnapDelay, forKey: Keys.windowSnapDelay) }
    }

    @Published public var windowSnapPreview: Bool {
        didSet { defaults.set(windowSnapPreview, forKey: Keys.windowSnapPreview) }
    }

    @Published public var windowCornerSnap: Bool {
        didSet { defaults.set(windowCornerSnap, forKey: Keys.windowCornerSnap) }
    }

    @Published public var windowMultiDisplayBorder: Bool {
        didSet { defaults.set(windowMultiDisplayBorder, forKey: Keys.windowMultiDisplayBorder) }
    }

    /// Pixel gap between snapped windows + screen edge. 0 = none.
    @Published public var windowGap: Int {
        didSet { defaults.set(windowGap, forKey: Keys.windowGap) }
    }

    /// Bundle IDs whose windows should never be drag-snapped. Keyboard
    /// shortcuts still work — the user is explicit there. Typical additions:
    /// Xcode, Photoshop, any app that doesn't play well with forced AX
    /// resize.
    @Published public var windowSnapExcludedBundleIDs: [String] {
        didSet {
            defaults.set(windowSnapExcludedBundleIDs, forKey: Keys.windowSnapExcludedBundleIDs)
        }
    }

    // MARK: - AI cleanup

    /// User-editable system prompt for the Foundation Models cleanup pass.
    /// Edits invalidate the cached LanguageModelSession.
    @Published public var aiCleanupPrompt: String {
        didSet {
            defaults.set(aiCleanupPrompt, forKey: Keys.aiCleanupPrompt)
            NotificationCenter.default.post(name: .katibCleanupPromptChanged, object: nil)
        }
    }

    /// Per-app prompt suffixes keyed on a regex over the bundle ID. Appended
    /// as an extra instruction line to the base prompt when the active app
    /// at recording-start matches.
    @Published public var aiCleanupAppProfiles: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(aiCleanupAppProfiles),
               let str = String(data: data, encoding: .utf8) {
                defaults.set(str, forKey: Keys.aiCleanupAppProfiles)
            }
            NotificationCenter.default.post(name: .katibCleanupPromptChanged, object: nil)
        }
    }

    // MARK: - Launch at login (system-backed, not UserDefaults)

    public var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                objectWillChange.send()
            } catch {
                Logger.shared.log("launchAtLogin toggle failed: \(error)")
            }
        }
    }

    // MARK: - Test isolation

    /// TEST-ONLY: redirect `defaults` to an in-memory suite so tests
    /// mutating settings can't persist to the user's real
    /// `UserDefaults.standard`. Call once in test target setUp before
    /// reading/writing settings. Production must never call this.
    /// Returns the isolated suite so tests can introspect the stored
    /// value if they need to verify persistence behavior.
    @discardableResult
    // swiftlint:disable:next identifier_name
    public func _useIsolatedTestStore() -> UserDefaults {
        let suite = UserDefaults(suiteName: "KatibTests-\(UUID().uuidString)") ?? .standard
        defaults = suite
        return suite
    }

    // MARK: - Init

    private init() {
        if let raw = defaults.string(forKey: Keys.hotkeySide),
           let side = HotkeySide(rawValue: raw) {
            self.hotkeySide = side
        } else {
            self.hotkeySide = .rightOption
        }
        self.playFeedbackSounds = defaults.object(forKey: Keys.playFeedbackSounds) as? Bool ?? true
        self.showLiveIndicator = defaults.object(forKey: Keys.showLiveIndicator) as? Bool ?? true
        self.checkForUpdates = defaults.object(forKey: Keys.checkForUpdates) as? Bool ?? true
        self.syncPluginDictionaries = defaults.object(forKey: Keys.syncPluginDictionaries) as? Bool ?? true
        self.debugTranscripts = defaults.object(forKey: Keys.debugTranscripts) as? Bool ?? false
        self.codeModeAppPattern = defaults.string(forKey: Keys.codeModeAppPattern)
            ?? Self.defaultCodeModeAppPattern
        self.saveDictationsToClipboard = defaults.object(forKey: Keys.saveDictationsToClipboard) as? Bool ?? true
        self.hasSeenWelcome = defaults.object(forKey: Keys.hasSeenWelcome) as? Bool ?? false
        self.aiPolishEnabled = defaults.object(forKey: Keys.aiPolishEnabled) as? Bool ?? false
        self.clipboardEnabled = defaults.object(forKey: Keys.clipboardEnabled) as? Bool ?? false
        let storedCap = defaults.integer(forKey: Keys.clipboardCapacity)
        // New-install / legacy-migration default is 100K. The picker
        // bottoms out at 50; anything stored below that is from the
        // pre-2025 era when the picker topped out at 200 and rather
        // than render an empty selection we snap to the modern default.
        // Existing users with any legitimate stored value (50+) keep
        // it untouched — bumping the default doesn't quietly raise
        // their disk footprint.
        if storedCap >= 50 {
            self.clipboardCapacity = storedCap
        } else {
            self.clipboardCapacity = 100_000
        }
        if let raw = defaults.string(forKey: Keys.clipboardRetention),
           let retention = ClipboardRetention(rawValue: raw) {
            self.clipboardRetention = retention
        } else {
            self.clipboardRetention = .unlimited
        }
        self.clipboardPlainTextPaste = defaults.object(forKey: Keys.clipboardPlainTextPaste) as? Bool ?? true
        self.screenshotEnabled = defaults.object(forKey: Keys.screenshotEnabled) as? Bool ?? true
        if let raw = defaults.string(forKey: Keys.screenshotSaveLocation),
           let loc = ScreenshotSaveLocation(rawValue: raw) {
            self.screenshotSaveLocation = loc
        } else {
            self.screenshotSaveLocation = .desktop
        }
        self.screenshotAutoCopy = defaults.object(forKey: Keys.screenshotAutoCopy) as? Bool ?? true
        self.screenshotAutoSave = defaults.object(forKey: Keys.screenshotAutoSave) as? Bool ?? true
        self.screenshotSkipEditor = defaults.object(forKey: Keys.screenshotSkipEditor) as? Bool ?? false
        self.screenshotRevealInFinder = defaults.object(forKey: Keys.screenshotRevealInFinder) as? Bool ?? false
        self.screenshotSubfolderName = defaults.string(forKey: Keys.screenshotSubfolderName) ?? "Katib Screenshots"
        let storedHotkeyCode = defaults.integer(forKey: Keys.clipboardHotkeyKeyCode)
        // kVK_ANSI_V == 9. Default combo is ⌥⌘V.
        self.clipboardHotkeyKeyCode = storedHotkeyCode > 0 ? UInt32(storedHotkeyCode) : 9
        let storedHotkeyMods = defaults.integer(forKey: Keys.clipboardHotkeyModifiers)
        // Carbon: cmdKey=0x100, optionKey=0x800 → together = 0x900.
        // Default ⇧⌃⌘V (0x1300). Was ⌥⌘V (0x900) but that conflicts with
        // the system's default paste in some apps; ⇧⌃⌘V is uncommon as an
        // app shortcut so it won't stomp on app-level bindings.
        self.clipboardHotkeyModifiers = storedHotkeyMods > 0 ? UInt32(storedHotkeyMods) : 0x1300

        // kVK_ANSI_3 == 20, kVK_ANSI_4 == 21. Default combos are ⇧⌘3 (quick)
        // and ⇧⌘4 (annotate). Both override Apple's system screenshot
        // shortcuts at the CGEventTap level — intentional; the user asked
        // Katib to own these.
        let storedQuickCode = defaults.integer(forKey: Keys.screenshotQuickHotkeyKeyCode)
        self.screenshotQuickHotkeyKeyCode = storedQuickCode > 0 ? UInt32(storedQuickCode) : 20
        let storedQuickMods = defaults.integer(forKey: Keys.screenshotQuickHotkeyModifiers)
        self.screenshotQuickHotkeyModifiers = storedQuickMods > 0 ? UInt32(storedQuickMods) : 0x300

        let storedAnnotateCode = defaults.integer(forKey: Keys.screenshotAnnotateHotkeyKeyCode)
        self.screenshotAnnotateHotkeyKeyCode = storedAnnotateCode > 0 ? UInt32(storedAnnotateCode) : 21
        let storedAnnotateMods = defaults.integer(forKey: Keys.screenshotAnnotateHotkeyModifiers)
        self.screenshotAnnotateHotkeyModifiers = storedAnnotateMods > 0 ? UInt32(storedAnnotateMods) : 0x300

        self.snippetExpansionEnabled = defaults.object(forKey: Keys.snippetExpansionEnabled) as? Bool ?? false
        let storedSnippetCode = defaults.integer(forKey: Keys.snippetHotkeyKeyCode)
        // kVK_Space == 49. Default combo is ⌃⌘Space.
        self.snippetHotkeyKeyCode = storedSnippetCode > 0 ? UInt32(storedSnippetCode) : 49
        let storedSnippetMods = defaults.integer(forKey: Keys.snippetHotkeyModifiers)
        // Carbon: cmdKey=0x100, controlKey=0x1000 → together = 0x1100.
        self.snippetHotkeyModifiers = storedSnippetMods > 0 ? UInt32(storedSnippetMods) : 0x1100
        self.snippetPrefixCharacter = defaults.string(forKey: Keys.snippetPrefixCharacter) ?? ";"

        if let raw = defaults.string(forKey: Keys.windowBindings),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: [UInt32]].self, from: data) {
            self.windowBindings = decoded
        } else {
            self.windowBindings = [:]
        }
        self.windowDragSnapEnabled = defaults.object(forKey: Keys.windowDragSnapEnabled) as? Bool ?? true
        self.windowSnapDelay = defaults.object(forKey: Keys.windowSnapDelay) as? Double ?? 0.2
        self.windowSnapPreview = defaults.object(forKey: Keys.windowSnapPreview) as? Bool ?? true
        self.windowCornerSnap = defaults.object(forKey: Keys.windowCornerSnap) as? Bool ?? true
        self.windowMultiDisplayBorder = defaults.object(forKey: Keys.windowMultiDisplayBorder) as? Bool ?? true
        self.windowGap = defaults.integer(forKey: Keys.windowGap)
        self.windowSnapExcludedBundleIDs = defaults.stringArray(forKey: Keys.windowSnapExcludedBundleIDs) ?? []
        self.aiCleanupPrompt = defaults.string(forKey: Keys.aiCleanupPrompt) ?? Self.defaultAICleanupPrompt
        if let raw = defaults.string(forKey: Keys.aiCleanupAppProfiles),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.aiCleanupAppProfiles = decoded
        } else {
            self.aiCleanupAppProfiles = Self.defaultAICleanupAppProfiles
        }
    }

    public var hotkeyDescription: String {
        "\(hotkeySide.displayName) (hold)"
    }
}

// MARK: - Shared notification names

extension Notification.Name {
    public static let katibHotkeyChanged = Notification.Name("katibHotkeyChanged")
    public static let katibCorrectionsChanged = Notification.Name("katibCorrectionsChanged")
    public static let katibPluginsChanged = Notification.Name("katibPluginsChanged")
    /// Posted when AppSettings.aiCleanupPrompt or aiCleanupAppProfiles changes.
    /// AICleanup observes this and invalidates its session cache.
    public static let katibCleanupPromptChanged = Notification.Name("katibCleanupPromptChanged")
}
