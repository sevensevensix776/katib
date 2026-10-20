import Foundation
import CoreGraphics

/// Every window-snap action Katib can perform. Each case computes a target
/// rect in *screen-space points with origin top-left* (the coordinate system
/// AX uses), given the active screen's visible frame and the current window
/// frame — necessary for actions like "almost maximize" or "center" that
/// reference the current size.
///
/// Pure logic, no AX / AppKit imports. Tested standalone.
public enum WindowAction: String, CaseIterable, Identifiable, Sendable {
    case maximize
    case almostMaximize
    case restore
    case center

    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf

    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    case nextDisplay
    case previousDisplay
    case larger
    case smaller

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost maximize"
        case .restore: return "Restore"
        case .center: return "Center"
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .topLeftQuarter: return "Top-left quarter"
        case .topRightQuarter: return "Top-right quarter"
        case .bottomLeftQuarter: return "Bottom-left quarter"
        case .bottomRightQuarter: return "Bottom-right quarter"
        case .nextDisplay: return "Move to next display"
        case .previousDisplay: return "Move to previous display"
        case .larger: return "Make larger"
        case .smaller: return "Make smaller"
        }
    }

    public var group: Group {
        switch self {
        case .maximize, .almostMaximize, .restore, .center, .larger, .smaller: return .resize
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return .halves
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter: return .quarters
        case .nextDisplay, .previousDisplay: return .display
        }
    }

    public enum Group: String, CaseIterable {
        case halves, quarters, resize, display
        public var displayName: String {
            switch self {
            case .halves: return "Halves"
            case .quarters: return "Quarters"
            case .resize: return "Resize"
            case .display: return "Display"
            }
        }
    }

    /// SF Symbol used in the Settings pane + command palette.
    public var symbol: String {
        switch self {
        case .maximize: return "rectangle.fill"
        case .almostMaximize: return "rectangle.inset.filled"
        case .restore: return "arrow.uturn.backward"
        case .center: return "rectangle.center.inset.filled"
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeftQuarter: return "rectangle.topleftfill.filled"
        case .topRightQuarter: return "rectangle.toprightfill.filled"
        case .bottomLeftQuarter: return "rectangle.bottomleftfill.filled"
        case .bottomRightQuarter: return "rectangle.bottomrightfill.filled"
        case .nextDisplay: return "arrow.right.to.line"
        case .previousDisplay: return "arrow.left.to.line"
        case .larger: return "arrow.up.left.and.down.right.magnifyingglass"
        case .smaller: return "minus.magnifyingglass"
        }
    }

    // MARK: - Frame calculation

    /// Compute the target frame in AX screen-space (origin top-left of screen,
    /// y grows downward). `visibleFrame` is in AX coordinates too — caller
    /// converts from NSScreen if needed.
    ///
    /// Returns nil when the action depends on something outside the current
    /// screen (e.g. `nextDisplay` — the manager routes those differently).
    public func targetFrame(
        visibleFrame: CGRect,
        currentFrame: CGRect
    ) -> CGRect? {
        let f = visibleFrame
        switch self {
        case .maximize:
            return f
        case .almostMaximize:
            let inset: CGFloat = 40
            return CGRect(x: f.minX + inset, y: f.minY + inset,
                          width: f.width - inset * 2, height: f.height - inset * 2)
        case .restore:
            // Half of the visible frame, centered. Nothing better without history.
            let w = f.width * 0.6, h = f.height * 0.6
            return CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
        case .center:
            let w = currentFrame.width, h = currentFrame.height
            return CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)

        case .leftHalf:
            return CGRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
        case .rightHalf:
            return CGRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
        case .topHalf:
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
        case .bottomHalf:
            return CGRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)

        case .topLeftQuarter:
            return CGRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height / 2)
        case .topRightQuarter:
            return CGRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height / 2)
        case .bottomLeftQuarter:
            return CGRect(x: f.minX, y: f.midY, width: f.width / 2, height: f.height / 2)
        case .bottomRightQuarter:
            return CGRect(x: f.midX, y: f.midY, width: f.width / 2, height: f.height / 2)

        case .larger:
            // Grow by 5% of visible frame on each side, clamped to the frame.
            let inset: CGFloat = -min(f.width, f.height) * 0.05
            let grown = currentFrame.insetBy(dx: inset, dy: inset)
            return grown.intersection(f)
        case .smaller:
            let inset: CGFloat = min(currentFrame.width, currentFrame.height) * 0.05
            return currentFrame.insetBy(dx: inset, dy: inset)

        case .nextDisplay, .previousDisplay:
            return nil
        }
    }
}
