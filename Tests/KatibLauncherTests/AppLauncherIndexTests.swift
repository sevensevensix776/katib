import XCTest
@testable import KatibLauncher

/// Tests cover the static `scan(roots:)` path — the file-system watcher
/// itself is left to manual testing (an XCTest harness for DispatchSource
/// fs events is fragile and mostly retests Apple's plumbing). What we do
/// test is the bit users feel: the right `.app` bundles surface, with the
/// right names, deduped sensibly, even when an Info.plist is corrupt or
/// missing.
final class AppLauncherIndexTests: XCTestCase {

    private var fixtureRoot: URL!

    override func setUp() async throws {
        fixtureRoot = try makeTempDir()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    // MARK: - Naming priority

    func testDisplayNameWinsOverBundleName() throws {
        try makeAppBundle(in: fixtureRoot, name: "FakeApp", info: [
            "CFBundleDisplayName": "Pretty Name",
            "CFBundleName": "Internal Name",
            "CFBundleIdentifier": "com.example.fake"
        ])
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries.first?.name, "Pretty Name")
    }

    func testBundleNameUsedWhenNoDisplayName() throws {
        try makeAppBundle(in: fixtureRoot, name: "FakeApp", info: [
            "CFBundleName": "Internal Name",
            "CFBundleIdentifier": "com.example.fake"
        ])
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries.first?.name, "Internal Name")
    }

    func testFilenameFallbackWhenInfoPlistMissing() throws {
        try makeAppBundle(in: fixtureRoot, name: "BareApp", info: nil)
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries.first?.name, "BareApp")
    }

    func testEmptyDisplayNameSkippedInFavorOfBundleName() throws {
        try makeAppBundle(in: fixtureRoot, name: "FakeApp", info: [
            "CFBundleDisplayName": "",
            "CFBundleName": "Real Name",
            "CFBundleIdentifier": "com.example.fake"
        ])
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries.first?.name, "Real Name")
    }

    // MARK: - ID stability

    func testBundleIdUsedWhenPresent() throws {
        try makeAppBundle(in: fixtureRoot, name: "FakeApp", info: [
            "CFBundleIdentifier": "com.example.fake"
        ])
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries.first?.id, "com.example.fake")
    }

    func testPathIdFallbackWhenBundleIdMissing() throws {
        try makeAppBundle(in: fixtureRoot, name: "FakeApp", info: [:])
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        let id = try XCTUnwrap(entries.first?.id)
        // macOS firmlinks `/var` → `/private/var`, so we compare by suffix
        // rather than full equality. The point of this assertion is that
        // the id is path-shaped and points at the bundle, not that we
        // can predict the canonicalization.
        XCTAssertTrue(id.hasSuffix("/FakeApp.app"), "id was \(id)")
        XCTAssertTrue(id.contains(fixtureRoot.lastPathComponent), "id was \(id)")
    }

    // MARK: - Robustness

    func testNonexistentRootSkippedSilently() {
        let bogus = URL(fileURLWithPath: "/this/path/does/not/exist/and/never/will")
        let entries = AppLauncherIndex.scan(roots: [bogus])
        XCTAssertEqual(entries, [])
    }

    func testCorruptInfoPlistFallsBackToFilename() throws {
        let appURL = fixtureRoot.appendingPathComponent("BrokenApp.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try Data("not a real plist".utf8).write(
            to: appURL.appendingPathComponent("Contents/Info.plist")
        )

        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries.first?.name, "BrokenApp")
        let id = try XCTUnwrap(entries.first?.id)
        XCTAssertTrue(id.hasSuffix("/BrokenApp.app"), "id was \(id)")
    }

    func testNonAppFilesIgnored() throws {
        try Data("hello".utf8).write(to: fixtureRoot.appendingPathComponent("README.txt"))
        try makeAppBundle(in: fixtureRoot, name: "RealApp", info: [
            "CFBundleIdentifier": "com.example.real"
        ])
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "RealApp")
    }

    func testNonDirectoryWithAppExtensionIgnored() throws {
        // Edge case: a file (not a directory) named "Fake.app" — symlinked
        // garbage. Should NOT produce an entry.
        try Data("imposter".utf8).write(to: fixtureRoot.appendingPathComponent("Fake.app"))
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries, [])
    }

    // MARK: - Sorting + dedup

    func testResultsSortedAlphabetically() throws {
        try makeAppBundle(in: fixtureRoot, name: "Zed", info: ["CFBundleIdentifier": "com.example.z"])
        try makeAppBundle(in: fixtureRoot, name: "Alfred", info: ["CFBundleIdentifier": "com.example.a"])
        try makeAppBundle(in: fixtureRoot, name: "Mango", info: ["CFBundleIdentifier": "com.example.m"])
        let names = AppLauncherIndex.scan(roots: [fixtureRoot]).map(\.name)
        XCTAssertEqual(names, ["Alfred", "Mango", "Zed"])
    }

    func testSortIsCaseInsensitive() throws {
        try makeAppBundle(in: fixtureRoot, name: "zed", info: ["CFBundleIdentifier": "com.example.z"])
        try makeAppBundle(in: fixtureRoot, name: "Alfred", info: ["CFBundleIdentifier": "com.example.a"])
        let names = AppLauncherIndex.scan(roots: [fixtureRoot]).map(\.name)
        XCTAssertEqual(names, ["Alfred", "zed"])
    }

    func testDuplicateBundleIdsAcrossRootsFirstWins() throws {
        let primary = try makeTempDir()
        let secondary = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: secondary)
        }

        try makeAppBundle(in: primary, name: "Primary", info: [
            "CFBundleDisplayName": "Primary",
            "CFBundleIdentifier": "com.example.dup"
        ])
        try makeAppBundle(in: secondary, name: "Secondary", info: [
            "CFBundleDisplayName": "Secondary",
            "CFBundleIdentifier": "com.example.dup"
        ])

        let entries = AppLauncherIndex.scan(roots: [primary, secondary])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "Primary")
    }

    func testDifferentBundleIdsKeepBothEvenWithSameName() throws {
        try makeAppBundle(in: fixtureRoot, name: "App-A", info: [
            "CFBundleDisplayName": "Same",
            "CFBundleIdentifier": "com.example.a"
        ])
        try makeAppBundle(in: fixtureRoot, name: "App-B", info: [
            "CFBundleDisplayName": "Same",
            "CFBundleIdentifier": "com.example.b"
        ])
        let entries = AppLauncherIndex.scan(roots: [fixtureRoot])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)), ["com.example.a", "com.example.b"])
    }

    // MARK: - URL field

    func testUrlPointsAtAppBundle() throws {
        try makeAppBundle(in: fixtureRoot, name: "Pointee", info: [
            "CFBundleIdentifier": "com.example.pointee"
        ])
        let entry = try XCTUnwrap(AppLauncherIndex.scan(roots: [fixtureRoot]).first)
        XCTAssertEqual(entry.url.lastPathComponent, "Pointee.app")
        XCTAssertTrue(entry.url.path.contains(fixtureRoot.lastPathComponent),
                      "url \(entry.url.path) did not contain fixture dir \(fixtureRoot.lastPathComponent)")
    }

    // MARK: - Symlinked .app bundles (regression: Safari is a cryptex symlink)

    /// macOS 26+ ships `/Applications/Safari.app` as a symlink into a
    /// cryptex volume. An earlier version of `scan` used the URL-based
    /// `contentsOfDirectory(at:includingPropertiesForKeys:options:)` which
    /// silently dropped symlinks that resolve across volume boundaries —
    /// the result was that Safari never appeared in the command palette,
    /// even though `ls /Applications/Safari.app` worked. Lock the
    /// path-based listing in with a fixture: a real `.app` plus a
    /// `.app` symlink that points at it. Both should be returned (deduped
    /// by bundle ID, so we use distinct IDs here).
    func testSymlinkedAppBundleIsIndexed() throws {
        let target = try makeTempDir()
        try makeAppBundle(in: target, name: "RealApp", info: [
            "CFBundleIdentifier": "com.example.real",
            "CFBundleDisplayName": "Real App"
        ])

        let symlinkRoot = try makeTempDir()
        let realAppURL = target.appendingPathComponent("RealApp.app")
        let symlinkURL = symlinkRoot.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realAppURL)

        let entries = AppLauncherIndex.scan(roots: [symlinkRoot])
        XCTAssertEqual(entries.count, 1, "Symlinked .app must be indexed")
        XCTAssertEqual(entries.first?.name, "Real App")
    }

    // MARK: - User-facing filter (regression: Finder must appear, BluetoothUIServer must not)

    /// `isUserFacing` lives in `KatibLauncher` so we can exercise the
    /// LSUIElement / LSBackgroundOnly plist gates directly without
    /// needing a CoreServices fixture path.
    func testIsUserFacingTrueForOrdinaryApp() throws {
        try makeAppBundle(in: fixtureRoot, name: "Ordinary", info: [
            "CFBundleIdentifier": "com.example.ordinary"
        ])
        let url = fixtureRoot.appendingPathComponent("Ordinary.app")
        XCTAssertTrue(AppLauncherIndex.isUserFacing(at: url))
    }

    func testIsUserFacingFalseForLSUIElement() throws {
        try makeAppBundle(in: fixtureRoot, name: "Agent", info: [
            "CFBundleIdentifier": "com.example.agent",
            "LSUIElement": true
        ])
        let url = fixtureRoot.appendingPathComponent("Agent.app")
        XCTAssertFalse(AppLauncherIndex.isUserFacing(at: url))
    }

    func testIsUserFacingFalseForLSBackgroundOnly() throws {
        try makeAppBundle(in: fixtureRoot, name: "Daemon", info: [
            "CFBundleIdentifier": "com.example.daemon",
            "LSBackgroundOnly": true
        ])
        let url = fixtureRoot.appendingPathComponent("Daemon.app")
        XCTAssertFalse(AppLauncherIndex.isUserFacing(at: url))
    }

    func testIsUserFacingTrueWhenPlistMissing() throws {
        try makeAppBundle(in: fixtureRoot, name: "NoPlist", info: nil)
        let url = fixtureRoot.appendingPathComponent("NoPlist.app")
        XCTAssertTrue(AppLauncherIndex.isUserFacing(at: url))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KatibLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // macOS firmlinks `/var` to `/private/var`. Without resolving here,
        // path-based assertions fail because `scan` walks the resolved
        // form. Settling on the resolved form keeps test expectations
        // honest.
        return url.resolvingSymlinksInPath()
    }

    /// Build a fake `.app` bundle: `Name.app/Contents/Info.plist`. Pass
    /// `info: nil` to skip writing the plist entirely (simulating a
    /// stub bundle).
    private func makeAppBundle(in root: URL, name: String, info: [String: Any]?) throws {
        let appURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        if let info {
            let plistURL = contents.appendingPathComponent("Info.plist")
            let data = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL)
        }
    }
}
