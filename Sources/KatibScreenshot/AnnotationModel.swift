import Foundation
import SwiftUI
import AppKit
import KatibCore

/// Annotation tools, stroke types, and the editable document state for
/// screenshot annotation. Separated from the canvas and window so the UI
/// renders from a single source of truth and the exporter flattens off the
/// same model.

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case rectangle
    case ellipse
    case highlight
    case blur
    case redact
    case text
    case number

    /// Tools surfaced in the editor toolbar. Blur + redact added 2026-05
    /// so screenshots of UI with sensitive text can ship safely without
    /// pulling the screenshot into a separate editor.
    static let toolbarVisible: [AnnotationTool] = [.select, .arrow, .rectangle, .text, .blur, .redact]

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .blur: return "aqi.medium"
        case .redact: return "eye.slash.fill"
        case .text: return "textformat"
        case .number: return "1.circle"
        }
    }

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .redact: return "Redact"
        case .text: return "Text"
        case .number: return "Step Number"
        }
    }

    /// Whether this tool creates a shape from two points (start + end) or
    /// requires click-to-place semantics.
    var isDragShape: Bool {
        switch self {
        case .arrow, .rectangle, .ellipse, .highlight, .blur, .redact: return true
        case .text, .number, .select: return false
        }
    }

    /// Whether drag points should be clamped to the image bounds. Arrow
    /// and text can live in the MARGIN around the screenshot (Droplr /
    /// CleanShot convention) — an arrow anchored off-image pointing at
    /// something inside, or a text label beside the image. Rectangles,
    /// ellipses, highlight, blur, redact must land on the image because
    /// they act on pixels. Numbered steps stay clamped — the whole point
    /// is to annotate specific regions inside the shot.
    var shouldClampToImage: Bool {
        switch self {
        case .arrow, .text: return false
        case .select, .rectangle, .ellipse, .highlight, .blur, .redact, .number: return true
        }
    }
}

/// A single annotation on the canvas. Coordinates are in the image's own
/// coordinate space (pixels), which keeps rendering and export consistent
/// regardless of on-screen zoom.
struct AnnotationStroke: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var color: Color
    var thickness: CGFloat
    /// Text payload for .text and .number tools.
    var text: String
    /// Numbered-step index — auto-assigned when stroke is committed.
    var stepIndex: Int?

    init(id: UUID = UUID(),
         tool: AnnotationTool,
         start: CGPoint,
         end: CGPoint,
         color: Color,
         thickness: CGFloat,
         text: String = "",
         stepIndex: Int? = nil) {
        self.id = id
        self.tool = tool
        self.start = start
        self.end = end
        self.color = color
        self.thickness = thickness
        self.text = text
        self.stepIndex = stepIndex
    }

    /// Normalized rectangle from start/end, regardless of drag direction.
    var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Visual bounding box of this stroke in image-space, accounting for
    /// per-tool ornamentation that `rect` alone misses: arrowheads extend
    /// past the endpoint, numbered-step circles are offset from `start`,
    /// text draws a bitmap sized by font metrics, thick strokes overflow
    /// their line. Used by the exporter to decide how far to extend the
    /// saved canvas past the image bounds.
    func visualBounds() -> CGRect {
        switch tool {
        case .select:
            // Select isn't a drawn stroke — return empty so no stroke with
            // this tool ever contributes to bounds. This case exists only
            // to satisfy the exhaustive switch; select strokes aren't
            // created, so this branch shouldn't be hit in practice.
            return .zero
        case .arrow:
            // Arrowhead extends `headLen` past end, `spread` perpendicular.
            let pad = max(thickness * 4, 18)
            return rect.insetBy(dx: -pad, dy: -pad)
        case .number:
            let size = max(22, thickness * 5)
            return CGRect(
                x: start.x - size / 2,
                y: start.y - size / 2,
                width: size, height: size
            )
        case .text:
            let fontSize = max(28, thickness * 6)
            // Rough monospace-ish estimate — good enough for canvas sizing.
            // Actual rendered width may differ slightly but the PNG drawing
            // context clips only to its own pixels, so undersizing by a
            // character or two costs a clipped edge, not a missing stroke.
            let width = CGFloat(max(1, text.count)) * fontSize * 0.6 + 12
            let height = fontSize * 1.4
            return CGRect(x: start.x, y: start.y, width: width, height: height)
        case .rectangle, .ellipse:
            return rect.insetBy(dx: -thickness / 2 - 2, dy: -thickness / 2 - 2)
        case .highlight, .blur, .redact:
            return rect
        }
    }
}

/// Live editor state. The annotation window binds to this; the canvas reads
/// `committed` + `inProgress` and the toolbar writes `currentTool`/`color`.
@MainActor
final class AnnotationState: ObservableObject {
    let image: NSImage
    let imageSize: CGSize

    @Published var committed: [AnnotationStroke] = []
    @Published var inProgress: AnnotationStroke?
    @Published var currentTool: AnnotationTool = .arrow
    @Published var currentColor: Color = .red
    @Published var currentThickness: CGFloat = 4
    /// ID of the currently-selected committed stroke. Non-nil only while
    /// the `.select` tool is active; cleared on tool change or click-to-
    /// empty-space. Drives the selection highlight + Delete-key removal.
    @Published var selectedStrokeID: UUID?

    /// View-only zoom multiplier on top of the fit-to-window base scale.
    /// 1.0 = default fit. Stored as user state so keyboard shortcuts +
    /// footer controls share one source of truth.
    @Published var zoom: CGFloat = 1.0
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 8.0
    /// Step multiplier per ⌘+ / ⌘- tap. 1.25 gives a slow, predictable ramp
    /// (log₁.₂₅ 8 ≈ 9 taps to reach max from 1.0).
    static let zoomStep: CGFloat = 1.25

    /// Index assigned to the next .number stroke.
    private var nextStepIndex: Int = 1

    /// Undo stack of prior `committed` arrays. Caps at 50 to avoid growth.
    private var undoStack: [[AnnotationStroke]] = []
    private let undoCap = 50

    init(image: NSImage) {
        self.image = image
        self.imageSize = image.size
    }

    /// Begin a drag at the given image-space point.
    func begin(at point: CGPoint) {
        let positioned = currentTool.shouldClampToImage ? clampToImage(point) : point
        switch currentTool {
        case .number:
            // Numbered steps place immediately on click.
            let stroke = AnnotationStroke(
                tool: .number,
                start: positioned,
                end: positioned,
                color: currentColor,
                thickness: currentThickness,
                stepIndex: nextStepIndex
            )
            nextStepIndex += 1
            pushUndo()
            committed.append(stroke)
            inProgress = nil
        case .text:
            // Click-to-commit-and-continue: if a text is already in
            // progress when the user clicks elsewhere, commit it first
            // (or discard if empty) so the new click creates a fresh
            // text. Without this, the new click overwrites the in-
            // progress text and the previous typing is silently lost —
            // the "after one text I can't add another" symptom.
            if let existing = inProgress, existing.tool == .text {
                commitText()
            }
            let stroke = AnnotationStroke(
                tool: .text,
                start: positioned,
                end: positioned,
                color: currentColor,
                thickness: currentThickness,
                text: ""
            )
            inProgress = stroke
        default:
            inProgress = AnnotationStroke(
                tool: currentTool,
                start: positioned,
                end: positioned,
                color: currentColor,
                thickness: currentThickness
            )
        }
    }

    /// Extend the in-progress stroke to a new drag point.
    func extend(to point: CGPoint) {
        guard var stroke = inProgress else { return }
        stroke.end = stroke.tool.shouldClampToImage ? clampToImage(point) : point
        inProgress = stroke
    }

    /// Commit the in-progress stroke. Called on drag-release by the canvas.
    func commitDrag() {
        guard let stroke = inProgress else { return }
        // Text strokes don't commit on drag release — they need the user
        // to actually type something via the toolbar's text field, which
        // calls `commitText()` on Return. Without this guard, mouse-up
        // immediately committed an empty placeholder and nil'd inProgress,
        // making the text field disappear before the user could type.
        if stroke.tool == .text { return }
        // Reject zero-size drags (accidental clicks) for shape tools.
        if stroke.tool.isDragShape,
           stroke.rect.width < 4, stroke.rect.height < 4 {
            inProgress = nil
            return
        }
        pushUndo()
        committed.append(stroke)
        inProgress = nil
    }

    /// Discard the in-progress stroke without committing.
    func cancelDrag() {
        inProgress = nil
    }

    /// Update the text of the most-recent text stroke (from the toolbar field).
    func updateInProgressText(_ newText: String) {
        inProgress?.text = newText
    }

    /// Commit a text stroke that was being edited. No-op if text empty.
    func commitText() {
        guard let stroke = inProgress, stroke.tool == .text,
              !stroke.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            inProgress = nil
            return
        }
        pushUndo()
        committed.append(stroke)
        inProgress = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        committed = previous
        // Re-derive the next step index so deleting doesn't strand numbers.
        let maxStep = committed.compactMap(\.stepIndex).max() ?? 0
        nextStepIndex = maxStep + 1
        inProgress = nil
    }

    func reset() {
        pushUndo()
        committed = []
        inProgress = nil
        nextStepIndex = 1
    }

    /// Hit-test committed strokes top-down (last drawn = top of stack) and
    /// select the first one whose visual bounds contain the image-space
    /// point. Returns whether something was selected.
    @discardableResult
    func selectStroke(at point: CGPoint) -> Bool {
        for stroke in committed.reversed() {
            if stroke.visualBounds().contains(point) {
                selectedStrokeID = stroke.id
                return true
            }
        }
        selectedStrokeID = nil
        return false
    }

    /// Offset the selected stroke's start/end by a delta (image-space).
    /// Called from the canvas drag handler when `.select` is active and a
    /// stroke is selected. Does NOT push undo — that's the mouse-up commit's
    /// job so a single drag gesture maps to one undoable step.
    func translateSelected(by delta: CGSize) {
        guard let id = selectedStrokeID,
              let idx = committed.firstIndex(where: { $0.id == id }) else { return }
        var stroke = committed[idx]
        stroke.start = CGPoint(x: stroke.start.x + delta.width, y: stroke.start.y + delta.height)
        stroke.end = CGPoint(x: stroke.end.x + delta.width, y: stroke.end.y + delta.height)
        committed[idx] = stroke
    }

    /// Snapshot the current state before a translation drag begins.
    func beginTranslateSelected() {
        pushUndo()
    }

    /// Remove the selected stroke. No-op if nothing is selected.
    func deleteSelected() {
        guard let id = selectedStrokeID,
              let idx = committed.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        committed.remove(at: idx)
        selectedStrokeID = nil
    }

    func zoomIn() {
        zoom = min(Self.maxZoom, zoom * Self.zoomStep)
    }

    func zoomOut() {
        zoom = max(Self.minZoom, zoom / Self.zoomStep)
    }

    func zoomReset() {
        zoom = 1.0
    }

    private func pushUndo() {
        undoStack.append(committed)
        if undoStack.count > undoCap { undoStack.removeFirst() }
    }

    private func clampToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), imageSize.width),
            y: min(max(0, point.y), imageSize.height)
        )
    }
}
