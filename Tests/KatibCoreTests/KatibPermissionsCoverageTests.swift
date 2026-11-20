import XCTest
@testable import KatibCore

/// Rule 8 of MACOS_PERMISSIONS_ONBOARDING.md: a permission API used in
/// Sources with no row in `KatibPermission.all` fails here, so a new feature
/// cannot ship an unexplained system prompt.
final class KatibPermissionsCoverageTests: XCTestCase {
    private var sourcesDir: URL {
        // Tests/KatibCoreTests/<this file> -> repo root -> Sources
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// marker -> files that mention it (the table file itself excluded).
    private func usage() throws -> [String: [String]] {
        var found: [String: [String]] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            if url.lastPathComponent == "KatibPermissions.swift" { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for marker in KatibPermission.watchedMarkers where text.contains(marker) {
                found[marker, default: []].append(url.lastPathComponent)
            }
        }
        // The scan must see the tree, or an empty result would pass for nothing.
        XCTAssertGreaterThan(scanned, 40, "scanned only \(scanned) files; Sources path moved?")
        return found
    }

    func testEveryPermissionAPIUsedInSourcesHasARow() throws {
        let covered = Set(KatibPermission.all.flatMap(\.apiMarkers))
        for (marker, files) in try usage() {
            XCTAssertTrue(covered.contains(marker),
                          "\(marker) is used in \(files) but has no row in KatibPermission.all. Add one (name, why, check, grant).")
        }
    }

    /// The scan must be able to fail: the markers Katib uses today are found.
    func testScanSeesTheMarkersKatibUsesToday() throws {
        let found = try usage()
        for marker in ["AXIsProcessTrusted", "CGPreflightScreenCaptureAccess", "AVCaptureDevice", "SFSpeechRecognizer"] {
            XCTAssertNotNil(found[marker], "scan missed \(marker)")
        }
    }

    func testTableHasOneRowPerIDWithCopy() {
        XCTAssertEqual(KatibPermission.all.map(\.id), KatibPermission.ID.allCases)
        for row in KatibPermission.all {
            XCTAssertFalse(row.name.isEmpty)
            XCTAssertFalse(row.why.isEmpty)
            XCTAssertFalse(row.symbol.isEmpty)
            XCTAssertFalse(row.apiMarkers.isEmpty)
        }
        XCTAssertFalse(KatibPermission.row(.screenRecording).required)
        XCTAssertEqual(KatibPermission.accessibilityName(osMajorVersion: 26), "Accessibility")
        XCTAssertEqual(KatibPermission.accessibilityName(osMajorVersion: 27), "Device Control and Data Access")
    }
}
