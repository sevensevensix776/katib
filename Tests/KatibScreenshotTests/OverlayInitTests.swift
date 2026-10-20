import XCTest
import AppKit
@testable import KatibScreenshot

/// Regression coverage for the Swift init-trap class of bug that crashed
/// v1.23.0 on every screenshot capture.
///
/// Pattern: when an NSWindow/NSView subclass provides its own designated
/// initializer, Swift stops inheriting the parent's designated inits and
/// synthesizes trapping overrides. If the parent's own init machinery later
/// dispatches to a child class via the Obj-C runtime (as NSWindow's 5-arg
/// init does when internally calling the 4-arg init), the synthesized trap
/// fires → SIGTRAP.
///
/// These tests exercise each at-risk subclass's designated init. They make
/// no assertions — the traps ARE the failure. Previously the whole test
/// process would abort on construction; now it completes.
@MainActor
final class OverlayInitTests: XCTestCase {

    /// Skip silently on headless runners where no screen is attached.
    private var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    /// Build a cheap single-pixel CGImage to stand in for a frozen display
    /// bitmap. The init trap we're guarding against fires on construction,
    /// not on draw, so the image contents don't matter.
    private func placeholderFrozen(for screen: NSScreen) -> CaptureOverlayWindow.FrozenDisplay {
        let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!
        return CaptureOverlayWindow.FrozenDisplay(screen: screen, image: image, scale: 1.0)
    }

    func testOverlayWindowConstructsWithoutTrapping() throws {
        guard let screen else {
            throw XCTSkip("No attached screen — skipping GUI-dependent test")
        }
        let coordinator = OverlayCoordinator(onPick: { _ in })
        // If the init trap from v1.23.0 regressed, this line would SIGTRAP
        // and the whole test process would exit. Reaching the next line is
        // the whole assertion.
        let window = OverlayWindow(frozen: placeholderFrozen(for: screen), coordinator: coordinator)
        XCTAssertEqual(window.frame.size, screen.frame.size)
    }

    func testOverlaySelectionViewConstructsWithoutTrapping() throws {
        guard let screen else {
            throw XCTSkip("No attached screen — skipping GUI-dependent test")
        }
        let coordinator = OverlayCoordinator(onPick: { _ in })
        let view = OverlaySelectionView(frozen: placeholderFrozen(for: screen), coordinator: coordinator)
        XCTAssertEqual(view.frame, screen.frame)
    }

    func testAnnotationWindowControllerConstructsWithoutTrapping() throws {
        // Uses NSWindow(contentViewController:) convenience init, which
        // sidesteps the designated-init delegation. Included so the whole
        // class of bug stays caught — if someone later refactors this
        // controller to subclass NSWindow, the test fires.
        let placeholderImage = NSImage(size: CGSize(width: 8, height: 8))
        let controller = AnnotationWindowController(
            image: placeholderImage,
            onCopy: { _ in },
            onSave: { _ in },
            onCancel: {}
        )
        XCTAssertNotNil(controller.window)
    }
}
