import AppKit
import KatibCore

/// Translucent floating NSWindow that previews the target frame during a
/// drag. Borderless, ignores mouse, tracks with pointer motion. Lives for
/// the duration of one drag — `show(frame:screen:)` creates/positions it,
/// `hide()` orders it out.
///
/// Visually: bronze-tinted fill with a thicker bronze border. Matches the
/// LiveIndicator + popover accent so the app reads as one piece.
@MainActor
final class SnapPreviewWindow {
    private var window: NSWindow?

    func show(frame: CGRect, on screen: NSScreen) {
        let nsFrame = nsFrame(fromAX: frame, screen: screen)

        if let window {
            window.setFrame(nsFrame, display: true, animate: false)
            if !window.isVisible { window.orderFront(nil) }
            return
        }

        let window = NSWindow(
            contentRect: nsFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.hasShadow = false
        window.ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: PreviewOverlayView())
        window.contentView = hostingView

        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 1
        }
        self.window = window
    }

    func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.window = nil
        })
    }

    /// AX coords are top-left origin; NSWindow.frame is bottom-left. Flip.
    private func nsFrame(fromAX ax: CGRect, screen: NSScreen) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return NSRect(
            x: ax.minX,
            y: primaryHeight - ax.maxY,
            width: ax.width,
            height: ax.height
        )
    }
}

import SwiftUI

/// The translucent rectangle itself — bronze tint, rounded corners, soft
/// edge. Designed to read "this is a preview" without dominating what's
/// underneath it.
private struct PreviewOverlayView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(AppColors.bronze.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.bronze.opacity(0.75), lineWidth: 2)
            )
            .padding(4)
    }
}
