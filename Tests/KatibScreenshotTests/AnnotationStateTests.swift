import XCTest
import SwiftUI
import AppKit
@testable import KatibScreenshot

/// Locks down AnnotationState's selection + translate + delete + text-
/// commit semantics. Every regression in this session has been a behavior
/// I assumed worked but didn't actually exercise — these tests pin the
/// contract so the next refactor can't silently break it.
@MainActor
final class AnnotationStateTests: XCTestCase {

    private func makeState() -> AnnotationState {
        AnnotationState(image: NSImage(size: CGSize(width: 1000, height: 800)))
    }

    private func addArrow(
        _ state: AnnotationState,
        from: CGPoint,
        to: CGPoint
    ) -> UUID {
        state.currentTool = .arrow
        state.begin(at: from)
        state.extend(to: to)
        state.commitDrag()
        return state.committed.last!.id
    }

    // MARK: - Selection: hit-test

    func testSelectsArrowWhenClickInsideVisualBounds() {
        let state = makeState()
        let id = addArrow(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        // Visual bounds for an arrow are the rect padded by max(thickness*4, 18).
        // Click in the middle of the arrow's bbox.
        XCTAssertTrue(state.selectStroke(at: CGPoint(x: 200, y: 150)))
        XCTAssertEqual(state.selectedStrokeID, id)
    }

    func testSelectClearsWhenClickOutsideAnyStroke() {
        let state = makeState()
        _ = addArrow(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        state.selectStroke(at: CGPoint(x: 200, y: 150)) // first select something
        XCTAssertNotNil(state.selectedStrokeID)

        XCTAssertFalse(state.selectStroke(at: CGPoint(x: 800, y: 700)))
        XCTAssertNil(state.selectedStrokeID, "Empty-space click must deselect")
    }

    func testTopmostStrokeWinsHitTest() {
        // Two overlapping rects; later-drawn = on top, should win selection.
        let state = makeState()
        state.currentTool = .rectangle
        state.begin(at: CGPoint(x: 100, y: 100))
        state.extend(to: CGPoint(x: 300, y: 300))
        state.commitDrag()
        let bottomID = state.committed.last!.id

        state.begin(at: CGPoint(x: 150, y: 150))
        state.extend(to: CGPoint(x: 250, y: 250))
        state.commitDrag()
        let topID = state.committed.last!.id

        // Click in the overlap region — topmost (last drawn) wins.
        state.selectStroke(at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(state.selectedStrokeID, topID)
        XCTAssertNotEqual(state.selectedStrokeID, bottomID)
    }

    // MARK: - Translate

    func testTranslateSelectedMovesBothStartAndEnd() {
        let state = makeState()
        _ = addArrow(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150))
        state.selectStroke(at: CGPoint(x: 150, y: 125))
        state.beginTranslateSelected()
        state.translateSelected(by: CGSize(width: 50, height: 30))

        let moved = state.committed.first!
        XCTAssertEqual(moved.start, CGPoint(x: 150, y: 130))
        XCTAssertEqual(moved.end, CGPoint(x: 250, y: 180))
    }

    func testTranslateNoOpWhenNothingSelected() {
        let state = makeState()
        _ = addArrow(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        // No select call → selectedStrokeID is nil.
        state.translateSelected(by: CGSize(width: 50, height: 50))
        let stroke = state.committed.first!
        XCTAssertEqual(stroke.start, CGPoint(x: 100, y: 100))
        XCTAssertEqual(stroke.end, CGPoint(x: 200, y: 200))
    }

    func testTranslateThenUndoRestoresOriginalPosition() {
        let state = makeState()
        _ = addArrow(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150))
        state.selectStroke(at: CGPoint(x: 150, y: 125))
        state.beginTranslateSelected()
        state.translateSelected(by: CGSize(width: 200, height: 200))
        state.undo()
        let restored = state.committed.first!
        XCTAssertEqual(restored.start, CGPoint(x: 100, y: 100))
        XCTAssertEqual(restored.end, CGPoint(x: 200, y: 150))
    }

    // MARK: - Delete

    func testDeleteSelectedRemovesStrokeAndClearsSelection() {
        let state = makeState()
        _ = addArrow(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        XCTAssertEqual(state.committed.count, 1)
        state.selectStroke(at: CGPoint(x: 150, y: 150))

        state.deleteSelected()
        XCTAssertEqual(state.committed.count, 0)
        XCTAssertNil(state.selectedStrokeID)
    }

    func testDeleteSelectedThenUndoBringsItBack() {
        let state = makeState()
        let id = addArrow(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        state.selectStroke(at: CGPoint(x: 150, y: 150))
        state.deleteSelected()
        state.undo()
        XCTAssertEqual(state.committed.count, 1)
        XCTAssertEqual(state.committed.first?.id, id)
    }

    func testDeleteSelectedNoOpWhenNothingSelected() {
        let state = makeState()
        _ = addArrow(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        XCTAssertNil(state.selectedStrokeID)
        state.deleteSelected()
        XCTAssertEqual(state.committed.count, 1, "Delete with no selection must not remove anything")
    }

    // MARK: - Text tool: click-to-commit-and-continue

    func testClickingNewLocationWhileTypingCommitsExistingText() {
        let state = makeState()
        state.currentTool = .text
        state.begin(at: CGPoint(x: 100, y: 100))
        state.updateInProgressText("hello")
        XCTAssertEqual(state.inProgress?.text, "hello")
        XCTAssertEqual(state.committed.count, 0)

        // Second click on a new location — should commit "hello" and
        // start a fresh in-progress text. This is the fix for the
        // "after one text I can't add another" regression.
        state.begin(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(state.committed.count, 1)
        XCTAssertEqual(state.committed.first?.text, "hello")
        XCTAssertEqual(state.inProgress?.start, CGPoint(x: 400, y: 300))
        XCTAssertEqual(state.inProgress?.text, "")
    }

    func testEmptyTextOnSecondClickIsDiscarded() {
        let state = makeState()
        state.currentTool = .text
        state.begin(at: CGPoint(x: 100, y: 100))
        // Don't type anything.
        state.begin(at: CGPoint(x: 400, y: 400))
        XCTAssertEqual(state.committed.count, 0, "Empty text must not commit")
        XCTAssertEqual(state.inProgress?.start, CGPoint(x: 400, y: 400))
    }

    func testTwoConsecutiveTextsCommitFirstAndStartSecond() {
        // The "click → type → click another spot → type" workflow. The
        // second click must commit the first text and start a new one
        // anchored at the second click. This was the regression: the
        // canvas's drag gesture skipped state.begin when inProgress was
        // non-nil, so the second click was a no-op.
        let state = makeState()
        state.currentTool = .text
        state.begin(at: CGPoint(x: 100, y: 100))
        state.updateInProgressText("first")
        state.begin(at: CGPoint(x: 400, y: 400))
        state.updateInProgressText("second")
        state.commitText()

        XCTAssertEqual(state.committed.count, 2)
        XCTAssertEqual(state.committed[0].text, "first")
        XCTAssertEqual(state.committed[0].start, CGPoint(x: 100, y: 100))
        XCTAssertEqual(state.committed[1].text, "second")
        XCTAssertEqual(state.committed[1].start, CGPoint(x: 400, y: 400))
    }

    func testCommitDragSkipsTextStrokes() {
        // Text strokes only commit via commitText; the canvas's mouseUp
        // (commitDrag) must not commit them. Otherwise the toolbar's
        // text field disappears before the user can type.
        let state = makeState()
        state.currentTool = .text
        state.begin(at: CGPoint(x: 100, y: 100))
        XCTAssertNotNil(state.inProgress)
        state.commitDrag()
        XCTAssertNotNil(state.inProgress, "Text must survive commitDrag — only commitText should commit it")
        XCTAssertEqual(state.committed.count, 0)
    }

    // MARK: - Defaults

    func testDefaultColorIsRed() {
        // Asif's pick: red is the most common annotation color, especially
        // for "look at this" arrows. Was bronze previously.
        let state = makeState()
        XCTAssertEqual(state.currentColor, .red)
    }

    func testDefaultToolIsArrow() {
        let state = makeState()
        XCTAssertEqual(state.currentTool, .arrow)
    }

    // MARK: - Zoom

    func testZoomInOutClampedToRange() {
        let state = makeState()
        // Hammer zoomIn past max — should saturate at maxZoom.
        for _ in 0..<50 { state.zoomIn() }
        XCTAssertEqual(state.zoom, AnnotationState.maxZoom, accuracy: 0.01)
        // Hammer zoomOut past min — should saturate at minZoom.
        for _ in 0..<50 { state.zoomOut() }
        XCTAssertEqual(state.zoom, AnnotationState.minZoom, accuracy: 0.01)
    }

    func testZoomResetReturnsToOne() {
        let state = makeState()
        state.zoom = 3.5
        state.zoomReset()
        XCTAssertEqual(state.zoom, 1.0)
    }
}
