# Katib

<img src="assets/katib-owl-256.png" width="128" alt="Katib owl scribe" align="right">

**كاتب — "The Scribe"**

A macOS menu-bar app for the small things you reach for all day. It started as on-device voice dictation (hold a key, speak, release, the words paste) and grew into a kit:

- **Dictation** with on-device speech recognition, a corrections dictionary and optional on-device AI polish
- **⌘Space command palette**: every Katib action, every installed app, System Settings panes and Spotlight file results in one fuzzy search, plus any search sources you add as [plugins](#plugins)
- **Clipboard history** with an Alfred-style picker (and an Alfred history import)
- **Screenshots**, straight to the clipboard or through an annotation editor with arrows, text, blur and redact
- **Window snapping** in the style of Rectangle, including Chrome, Electron apps and iTerm2
- **Voice commands**: _"split left"_, _"maximize"_, _"capture screen"_, _"paste last"_, plus Shortcuts and Siri through App Intents

Audio, transcripts, clipboard contents and screenshots stay on your Mac. Katib sends nothing anywhere unless a build turns on crash reporting (see [Privacy](#privacy)).

Built by 776. MIT licensed.

## Requirements

- **macOS 26 (Tahoe) or later** and an **Apple Silicon** Mac.
- Permissions, asked for on first launch: **Microphone**, **Speech Recognition**, **Accessibility**, **Screen Recording** (for screenshots).

## Install

Download the latest `Katib-<version>.dmg` from [Releases](https://github.com/sevensevensix776/katib/releases), open it, drag Katib to Applications and open it. A welcome window walks you through the permissions and a test dictation. Then look for **ك** in the menu bar.

Or [build it yourself](#build-from-source).

**Upgrading:** quit Katib from the menu bar first, then replace the app. Replacing a running copy can break paste until you grant Accessibility again.

**Heads-up:** Katib takes over **⇧⌘3** and **⇧⌘4** for its own screenshots, and **⌘Space** for its palette when Spotlight's shortcut is off (otherwise **⇧⌘K**). You can change every shortcut in Settings → Shortcuts.

## Shortcuts

| Action | Shortcut |
|---|---|
| Command palette | **⌘Space**, or **⇧⌘K** if Spotlight owns ⌘Space |
| Dictate | Hold **Right Option**, speak, release |
| Paste the last dictation again | Double-tap **Right Option** |
| Cancel a dictation | **Esc** while holding the key |
| Clipboard picker | **⇧⌃⌘V**, then search, or **⌘1–⌘9** |
| Screenshot to clipboard | **⇧⌘3** |
| Screenshot and annotate | **⇧⌘4** |
| Window snap | Set in Settings → Shortcuts |

**Annotation editor:** **⌘⏎** copies and closes, **⌘S** saves, **⌘Z** undoes, **Delete** removes the selected mark, **⌘=** / **⌘-** / **⌘0** zoom. Screenshots also save to `~/Desktop/Katib Screenshots` (Settings → Screenshot).

**Voice commands:** say the phrase instead of dictating: _"split left"_, _"maximize"_, _"new paragraph"_, _"paste last"_, _"cancel"_, _"open settings"_, _"capture screen"_.

Katib refuses to paste into password fields, and when the frontmost app changed between the start and the end of a dictation. The dictation is then kept in the menu bar popover so you can paste it again.

## What ⌘Space searches

| Source | What is matched | Opens |
|---|---|---|
| Commands | Katib's actions (dictation, clipboard, screenshot, window snaps…), fuzzy and ranked by use | Runs the action |
| Settings | The System Settings panes Katib needs (Accessibility, Microphone, Speech, Screen Recording…) | That pane |
| Apps | App names in `/Applications`, `/System/Applications`, `~/Applications` and user-facing CoreServices apps | The app |
| Plugins | Whatever each search plugin returns, under the plugin's own header | The hit's URL |
| Files | File and folder **names** under your home folder (Spotlight), top 10 by recent change | The default app |

## Dictation

- **On-device recognition** with Apple's SpeechAnalyzer. Up to 100 names and terms from your dictionaries are passed to the recognizer before each recording, so it hears them better.
- **Corrections**, in layers (each wins over the one before): built-in defaults, [plugin dictionaries](#plugins), learned terms, then your own corrections (menu bar → Edit corrections…).
- **AI polish** (off by default): a pass through Apple's on-device Foundation Models removes fillers and restarts. Guards reject any pass that rewrites your meaning. Costs about 2 seconds.
- **Code mode**: in editors and terminals, "my app dash api" becomes `my-app-api`. The app list is in Settings → Advanced.

## Plugins

A plugin adds to Katib without a rebuild. It is a folder with a `plugin.json`, in one of two places (the second wins when both hold the same `id`):

1. `Katib.app/Contents/Resources/Plugins/` (bundled by an [edition](#editions))
2. `~/Library/Application Support/Katib/Plugins/` (your own; Settings → General → Plugins → Open Plugins Folder)

A plugin can do either or both:

```json
{
  "id": "notes",
  "name": "Notes",
  "search": {
    "command": ["bin/search"],
    "minQueryLength": 3,
    "timeout": 6,
    "limit": 6,
    "symbol": "books.vertical",
    "color": "purple"
  },
  "dictionary": {
    "file": "dictionary.json",
    "syncURL": "https://example.com/notes-dictionary.json"
  }
}
```

**Search.** Katib runs `command` (no shell; a relative path is inside the plugin folder) with the query as the last argument, and reads JSON from stdout:

```json
{"items": [{"id": "a1", "title": "Weekly notes", "subtitle": "notes/weekly.md:12", "url": "https://…", "snippet": "the [matched] words"}]}
```

Only `title` is required. `url` is opened on Return (web URL, file URL or absolute path). `[brackets]` in `snippet` show in bold. A non-zero exit or a timeout shows as a short note in the plugin's header; a missing executable shows nothing. `id`: lowercase letters, digits and `-`.

**Dictionary.** `file` has the same shape as your corrections file:

```json
{"dictionary": {"zephyr": "Zephyr"}, "phonetic": {"zeff year": "Zephyr"}, "replacements": {}}
```

With `syncURL`, Katib re-fetches it every 6 hours (Settings → Sync plugin dictionaries) and keeps the copy in `~/Library/Application Support/Katib/PluginCache/<id>/`. A plugin can guard its own entries with a `dictionary-tests.json`; run them with `KATIB_TEST_PLUGINS=<Plugins folder> swift test --filter testPluginDictionaryTests`.

Plugins load at launch and each time the palette opens; Settings → Reload picks up a changed dictionary.

## Privacy

- Everything runs on your Mac: speech recognition, AI polish, clipboard history, screenshots.
- Katib keeps transcripts in memory for the popover's recent list and writes only the app name, word count and duration of each dictation to `~/Library/Application Support/VoiceTools/history.jsonl`. Settings → Advanced → Debug can log transcripts to `~/Library/Logs/Katib/katib.log` for troubleshooting; it is off by default.
- Clipboard history is off by default.
- **Crash reporting** is off in a source build. An edition can turn on Sentry by naming a DSN; then crash events carry no transcript text (long messages are redacted and dictation breadcrumbs dropped).
- The update check reads `latest.json` from this repository every 6 hours (Settings → General to turn off).

## Build from source

```bash
./build-app.sh                  # Katib.app (ad-hoc signed without a Developer ID cert)
./build-app.sh --launch         # build, then quit and relaunch Katib (waits for an open dictation)
./build-app.sh --release        # Developer ID, notarized, stapled DMG
swift test                      # unit tests
swiftlint                       # brew install swiftlint
./scripts/install-hooks.sh      # pre-commit hook: tests + lint
```

An ad-hoc build runs fine, but macOS treats each rebuild as a new app, so you grant Accessibility and Microphone again after a rebuild. Signing with your own Developer ID (`SIGN_ID="Developer ID Application: …"` or `KATIB_TEAM_ID=<team>`) keeps the grants.

`--release` needs a Developer ID Application certificate and notarization credentials:

```bash
export NOTARY_KEY_FILE=~/.config/katib/AuthKey_XXXXXXXXXX.p8
export NOTARY_KEY_ID=XXXXXXXXXX
export NOTARY_ISSUER=<issuer-uuid>
```

**Self-tests without keystrokes:**

```bash
open Katib.app --args -paletteQuery "text"   # opens ⌘Space with a query typed in
open Katib.app --args -showPopover YES       # opens the menu bar popover
KATIB_OWL_PREVIEW=/tmp swift test --filter OwlSpriteTests   # renders the owl's frames
```

**The owl.** The dictation window's pixel owl lives in `Sources/KatibDictation/Views/OwlSprite.swift` as text grids, one character per pixel. NES rules: 24x24, two palettes of 3 colours, held frames, no easing.

### Editions

An edition is Katib plus one team's extras, kept in a private folder and added at build time:

```
edition/
  edition.json        {"sentryDSN": "https://…", "updateManifestURL": "https://…/latest.json"}
  Plugins/            plugins bundled into the app (a team dictionary, a search source)
```

```bash
./build-app.sh --release --edition=/path/to/edition
```

The keys go into `Info.plist` (`KatibSentryDSN`, `KatibUpdateManifestURL`) and the plugins into `Contents/Resources/Plugins`. Executables in bundled plugins are signed with the app.

## Modules

Feature libraries depend only on `KatibCore`; the executable wires them together.

| Module | What it owns |
|---|---|
| **KatibCore** | Settings, logging, update check, plugin registry, command registry, fuzzy match and frecency, `HotkeyTapRouter` (the one shared `CGEventTap` behind every global shortcut) |
| **KatibDictation** | Hotkey, `StreamingTranscriber`, paste with the secure-field guard, AI polish, `TextCorrectionEngine` and plugin dictionaries, voice commands, the dictation window and owl |
| **KatibClipboard** | Clipboard history and its picker |
| **KatibScreenshot** | Capture (ScreenCaptureKit), area select, the annotation editor and exporter |
| **KatibWindow** | Window snap actions (Accessibility API), shortcut bindings, drag-to-snap |
| **KatibLauncher** | App index, Spotlight file search, plugin search |
| **KatibSnippets** | Text expander (built, hidden from the UI) |
| **Katib** | App delegate, menu bar, settings, command palette, App Intents, Sentry wiring |

All global shortcuts ride one `CGEventTap`: one permission, one recovery path, and it can override Apple-reserved combos like ⇧⌘3.

## Troubleshooting

- **A shortcut does nothing, or a snap does not move the window**: Accessibility is missing. System Settings → Privacy & Security → Accessibility (macOS 27: Device Control and Data Access) → turn Katib off and on again.
- **"Didn't catch that"**: the mic may be muted or the wrong input selected, or the key was released too fast.
- **Garbled dictations**: quit and reopen Katib; SpeechAnalyzer sometimes gets stuck until a restart.
- **Half-screen snaps stop short of the bottom**: macOS 27 can keep reserving Dock space while the Dock hides. Katib restarts the Dock once when it sees this; by hand: `killall Dock`.
- **iTerm2 does not resize on snap**: `defaults write com.googlecode.iterm2 DisableWindowSizeSnap -integer 1`, then restart iTerm2.
- **A plugin's header shows an orange note**: its command failed or took longer than its `timeout`. The log says which: `PluginSearch[<id>]`.
- Logs: `~/Library/Logs/Katib/katib.log`.

## Contributing

Issues and pull requests are welcome. Run `./scripts/install-hooks.sh` once so each commit runs the tests and SwiftLint. Keep tests few and sharp: one per real failure.

## License

[MIT](LICENSE)
