import XCTest
@testable import KatibCore

/// Locks down the pure transition decision used by BootstrapCoordinator.
/// The coordinator itself owns timers, AppKit, and OS permission APIs
/// and is harder to unit-test, but the decision function is pure: given
/// (current state, permission snapshot) it returns one of four actions.
/// If the state machine grows a new edge in the future and someone
/// forgets to handle it, these tests fail at PR time rather than at
/// 3am on a teammate's machine.
final class BootstrapDecisionTests: XCTestCase {

    // MARK: - Forward path (waiting → bootstrapping)

    func testWaitingWithAllGrantedAdvances() {
        let action = bootstrapAction(from: .waiting, snapshot: .granted)
        XCTAssertEqual(action, .advance)
    }

    func testWaitingWithAnyMissingStaysNoop() {
        let cases: [PermissionSnapshot] = [
            .denied,
            PermissionSnapshot(mic: false, speech: true,  accessibility: true),
            PermissionSnapshot(mic: true,  speech: false, accessibility: true),
            PermissionSnapshot(mic: true,  speech: true,  accessibility: false),
            PermissionSnapshot(mic: true,  speech: false, accessibility: false),
            PermissionSnapshot(mic: false, speech: true,  accessibility: false),
            PermissionSnapshot(mic: false, speech: false, accessibility: true)
        ]
        for snap in cases {
            XCTAssertEqual(
                bootstrapAction(from: .waiting, snapshot: snap), .noop,
                "waiting + \(snap.summary) should noop, not advance"
            )
        }
    }

    // MARK: - Reverse path (bootstrapped → waiting on revoke)

    func testBootstrappedWithRevokedRetreats() {
        let revokedSnaps: [PermissionSnapshot] = [
            .denied,
            PermissionSnapshot(mic: false, speech: true,  accessibility: true),
            PermissionSnapshot(mic: true,  speech: false, accessibility: true),
            PermissionSnapshot(mic: true,  speech: true,  accessibility: false)
        ]
        for snap in revokedSnaps {
            let action = bootstrapAction(from: .bootstrapped, snapshot: snap)
            guard case .retreat(let reason) = action else {
                XCTFail("expected retreat for \(snap.summary), got \(action)")
                continue
            }
            XCTAssertTrue(
                reason.contains(snap.summary),
                "retreat reason should embed the snapshot for forensic logging; got \(reason)"
            )
        }
    }

    func testBootstrappedWithAllGrantedStaysNoop() {
        // Already done — don't re-bootstrap on every poll tick.
        XCTAssertEqual(
            bootstrapAction(from: .bootstrapped, snapshot: .granted),
            .noop
        )
    }

    // MARK: - Mid-flight cancellation (bootstrapping → waiting on revoke)

    func testBootstrappingWithRevokedCancels() {
        let action = bootstrapAction(
            from: .bootstrapping,
            snapshot: PermissionSnapshot(mic: true, speech: true, accessibility: false)
        )
        guard case .cancel(let reason) = action else {
            XCTFail("expected cancel, got \(action)")
            return
        }
        XCTAssertTrue(reason.contains("a11y=false"), "got \(reason)")
    }

    func testBootstrappingWithAllGrantedStaysNoop() {
        // Already in flight; a duplicate "all granted" tick must NOT
        // double-bootstrap. This was codex's specific concern: ad-hoc
        // observers that fire twice in the same loop tick.
        XCTAssertEqual(
            bootstrapAction(from: .bootstrapping, snapshot: .granted),
            .noop
        )
    }

    // MARK: - Idempotence

    func testRepeatedEvaluationFromSameStateNoSnapshotChangeIsIdempotent() {
        // Three back-to-back ticks at .waiting + .denied should all
        // produce .noop. If the state machine ever grows hidden state
        // that breaks this, we want to catch it here.
        for _ in 0..<3 {
            XCTAssertEqual(bootstrapAction(from: .waiting, snapshot: .denied), .noop)
            XCTAssertEqual(bootstrapAction(from: .bootstrapped, snapshot: .granted), .noop)
        }
    }

    // MARK: - Snapshot helpers

    func testAllGrantedRequiresAllThree() {
        XCTAssertTrue(PermissionSnapshot.granted.allGranted)
        XCTAssertFalse(PermissionSnapshot.denied.allGranted)
        XCTAssertFalse(
            PermissionSnapshot(mic: true, speech: true, accessibility: false).allGranted,
            "missing AX = not granted"
        )
        XCTAssertFalse(
            PermissionSnapshot(mic: false, speech: true, accessibility: true).allGranted,
            "missing mic = not granted"
        )
        XCTAssertFalse(
            PermissionSnapshot(mic: true, speech: false, accessibility: true).allGranted,
            "missing speech = not granted"
        )
    }

    func testSummaryFormatStable() {
        // Format must stay grep-able — we mine logs for "mic=" / "speech=" / "a11y=".
        let snap = PermissionSnapshot(mic: true, speech: false, accessibility: true)
        XCTAssertEqual(snap.summary, "mic=true speech=false a11y=true")
    }
}
