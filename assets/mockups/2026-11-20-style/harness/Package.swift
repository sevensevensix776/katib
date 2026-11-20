// swift-tools-version: 6.0
import PackageDescription
// Mockup renderer only. Not part of the Katib package; ships nothing.
let package = Package(
    name: "mock",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "mock", path: "Sources/mock", swiftSettings: [.swiftLanguageMode(.v5)])]
)
