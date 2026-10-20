// swift-tools-version: 6.1
import PackageDescription

/// Katib is split into feature libraries that each depend only on KatibCore.
/// The executable target (Katib) wires them together. Keeps blast radius
/// tight: a change to the clipboard code doesn't recompile screenshot or
/// dictation code, and each feature's public surface is explicit.
///
///   KatibCore        ← shared settings, colors, logging, telemetry, updates
///   KatibDictation   ← hotkey + transcription + corrections + dictation UI
///   KatibClipboard   ← clipboard history manager + clipboard pane
///   KatibScreenshot  ← region capture + annotation editor
///   Katib            ← executable shell (AppDelegate, menu bar, settings,
///                      App Intents, Sentry init)
///
let package = Package(
    name: "Katib",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Katib", targets: ["Katib"])
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0")
    ],
    targets: [
        .target(
            name: "KatibCore",
            path: "Sources/KatibCore"
        ),
        .target(
            name: "KatibDictation",
            dependencies: ["KatibCore"],
            path: "Sources/KatibDictation",
            resources: [
                .copy("Resources/default-corrections.json")
            ]
        ),
        .target(
            name: "KatibClipboard",
            dependencies: ["KatibCore"],
            path: "Sources/KatibClipboard"
        ),
        .target(
            name: "KatibScreenshot",
            dependencies: ["KatibCore"],
            path: "Sources/KatibScreenshot"
        ),
        .target(
            name: "KatibWindow",
            dependencies: ["KatibCore"],
            path: "Sources/KatibWindow"
        ),
        .target(
            name: "KatibSnippets",
            dependencies: ["KatibCore"],
            path: "Sources/KatibSnippets"
        ),
        .target(
            name: "KatibLauncher",
            dependencies: ["KatibCore"],
            path: "Sources/KatibLauncher"
        ),
        .executableTarget(
            name: "Katib",
            dependencies: [
                "KatibCore",
                "KatibDictation",
                "KatibClipboard",
                "KatibScreenshot",
                "KatibWindow",
                "KatibSnippets",
                "KatibLauncher",
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            path: "Sources/Katib"
        ),

        .testTarget(
            name: "KatibCoreTests",
            dependencies: ["KatibCore"],
            path: "Tests/KatibCoreTests"
        ),
        .testTarget(
            name: "KatibDictationTests",
            dependencies: ["KatibDictation", "KatibCore"],
            path: "Tests/KatibDictationTests"
        ),
        .testTarget(
            name: "KatibClipboardTests",
            dependencies: ["KatibClipboard", "KatibCore"],
            path: "Tests/KatibClipboardTests"
        ),
        .testTarget(
            name: "KatibWindowTests",
            dependencies: ["KatibWindow", "KatibCore"],
            path: "Tests/KatibWindowTests"
        ),
        .testTarget(
            name: "KatibScreenshotTests",
            dependencies: ["KatibScreenshot", "KatibCore"],
            path: "Tests/KatibScreenshotTests"
        ),
        .testTarget(
            name: "KatibSnippetsTests",
            dependencies: ["KatibSnippets", "KatibCore"],
            path: "Tests/KatibSnippetsTests"
        ),
        .testTarget(
            name: "KatibLauncherTests",
            dependencies: ["KatibLauncher", "KatibCore"],
            path: "Tests/KatibLauncherTests"
        )
    ]
)
