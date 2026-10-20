import XCTest
import os
@testable import KatibCore

/// Locks down the closure-isolation contract that exists because of the
/// crash fixed in `cd3c404`.
///
/// The bug: a closure declared inside a SwiftUI View body or any
/// `@MainActor` type was inferred `@MainActor` by Swift 6's strict
/// concurrency. When that closure was passed as a completion handler
/// to `AVCaptureDevice.requestAccess` / `SFSpeechRecognizer.requestAuthorization`,
/// TCC invoked it on its own dispatch queue (background, not main).
/// Swift's runtime check fired `dispatch_assert_queue_fail` → SIGTRAP.
/// Crash report KATIB-5 in Sentry.
///
/// The fix is to mark every such closure `@Sendable` explicitly. These
/// tests exercise the pattern at runtime so we have a living, executable
/// document of "this is the shape that must keep working." They don't
/// reproduce the failure mode — a crashing test would fail CI on the
/// wrong side. The actual prevention against regression is code review
/// + the audit captured in the v2.1.1 release notes; these tests are
/// the breadcrumb that explains why every TCC-style callback in the
/// codebase carries `@Sendable`.
@MainActor
final class SendableClosureContractTests: XCTestCase {

    /// Empty completion handler — mimics MenuBarView.permissionStack's
    /// "kick off the TCC prompt and let the BootstrapCoordinator poll
    /// for the result" pattern.
    func testEmptyHandlerSurvivesBackgroundInvocation() async {
        let exp = expectation(description: "handler invoked from background")
        let handler: @Sendable (Bool) -> Void = { _ in
            exp.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            handler(true)
        }
        await fulfillment(of: [exp], timeout: 1.0)
    }

    /// Nested-Task pattern — mimics SettingsView.requestMicrophone's
    /// "outer closure is Sendable, inner Task hops back to MainActor
    /// for UI refresh" pattern.
    func testHandlerWithMainActorHopReachesMain() async {
        let onMain = expectation(description: "Task body ran on main")
        let handler: @Sendable (Bool) -> Void = { _ in
            Task { @MainActor in
                XCTAssertTrue(Thread.isMainThread,
                              "Task @MainActor must dispatch the body on main")
                onMain.fulfill()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            handler(true)
        }
        await fulfillment(of: [onMain], timeout: 1.0)
    }

    /// Demonstrates the same handler shape works when invoked SYNCHRONOUSLY
    /// from a background queue. The bug surfaced from sync invocation
    /// inside `__TCCAccessRequest_block_invoke`, which is dispatched but
    /// then runs the handler synchronously on that queue. Important to
    /// confirm we don't accidentally rely on async-only behavior.
    func testHandlerInvokedSynchronouslyFromBackground() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let handler: @Sendable (Int) -> Void = { _ in
            calls.withLock { $0 += 1 }
        }

        let queue = DispatchQueue(label: "test.tcc-mimic")
        queue.sync {
            handler(1)
            handler(2)
            handler(3)
        }

        XCTAssertEqual(calls.withLock { $0 }, 3)
    }
}
