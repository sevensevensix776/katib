import CoreGraphics

/// Pure helper for deciding whether a mouseDown-then-cursor-movement
/// sequence has crossed the threshold for committing to "this is a real
/// window drag" vs. "this was just a click in the title bar zone."
///
/// The rule, in plain English: the user must move the cursor at least
/// `cursorActivationThreshold` points AND the window's AX position must
/// have moved at least `windowMoveThreshold` points. The window-movement
/// check is what excludes in-window drags (Chrome tab reorder, Slack
/// channel-list resize, etc.) where the cursor moves but the window
/// itself never starts moving.
public struct DragActivation: Sendable, Equatable {
    public let cursorActivationThreshold: CGFloat
    public let windowMoveThreshold: CGFloat

    public init(cursorActivationThreshold: CGFloat, windowMoveThreshold: CGFloat) {
        self.cursorActivationThreshold = cursorActivationThreshold
        self.windowMoveThreshold = windowMoveThreshold
    }

    public func shouldActivate(cursorDelta: CGFloat, windowDelta: CGFloat) -> Bool {
        cursorDelta >= cursorActivationThreshold && windowDelta >= windowMoveThreshold
    }
}
