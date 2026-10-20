import SwiftUI
import AppKit
import KatibCore

/// Renders the screenshot + all annotations with SwiftUI Canvas.
/// Drag gesture feeds the AnnotationState. Pointer-to-image coordinate
/// conversion uses the canvas size so the same stroke data renders and
/// exports identically regardless of on-screen scale.
@MainActor
struct AnnotationCanvas: View {
    @ObservedObject var state: AnnotationState

    /// Zoom level at the start of the current pinch gesture, so
    /// MagnifyGesture's relative magnification applies to a stable base
    /// instead of compounding during the gesture.
    @State private var zoomAtGestureStart: CGFloat?

    /// Last drag point (image-space) for the select tool's translate
    /// gesture. Non-nil only during an active drag on a selected stroke.
    @State private var translateLastPoint: CGPoint?

    /// Set on the first onChanged tick of the current gesture. Lets us
    /// distinguish "mouse just went down" from "mouse is being dragged."
    /// Critical for the text tool — every mouse-down should begin a fresh
    /// text annotation (committing any in-progress one), but onChanged
    /// fires repeatedly so we need a per-gesture latch.
    @State private var gestureBegan: Bool = false

    /// Focus state for the inline text annotation field. Bound so we can
    /// auto-focus the moment a text stroke goes in-progress.
    @FocusState private var inlineTextFieldFocused: Bool

    var body: some View {
        GeometryReader { geo in
            // Fit-to-window (capped at 1.5x for tiny images) times the
            // user's zoom. Zoom is pure multiplier on top of the fit so
            // 1.0 = "what the editor shows by default".
            let baseScale = fittingScale(containerSize: geo.size)
            let scale = baseScale * state.zoom
            let renderedSize = CGSize(
                width: state.imageSize.width * scale,
                height: state.imageSize.height * scale
            )
            // Canvas surface grows to at least geo.size so margins are
            // usable (arrow/text can start outside the image). When zoomed
            // in past geo.size, the surface expands and the ScrollView
            // pans. When smaller, we center via `offset`.
            let surfaceSize = CGSize(
                width: max(geo.size.width, renderedSize.width),
                height: max(geo.size.height, renderedSize.height)
            )
            let offset = CGSize(
                width: (surfaceSize.width - renderedSize.width) / 2,
                height: (surfaceSize.height - renderedSize.height) / 2
            )

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: state.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: renderedSize.width, height: renderedSize.height)
                        .offset(offset)

                    // Live blur preview. SwiftUI's native .blur (Metal)
                    // is cheap enough to run every frame during a drag —
                    // no CIFilter roundtrip needed.
                    //
                    // Coordinate gotcha: the mask is rendered in the
                    // masked view's local space (the renderedSize frame
                    // BEFORE .offset is applied). So mask rects must be
                    // in image-scaled space (no surface offset). The
                    // .offset comes AFTER .mask so the whole composite
                    // — image + mask — moves together to land on top of
                    // the underlying screenshot. Earlier version added
                    // the surface offset to the mask rects too, which
                    // double-offset them and pushed the visible blur
                    // region down-right of the actual stroke.
                    let blurRectsImageSpace = scaledBlurRectsImageSpace(imageScale: scale)
                    if !blurRectsImageSpace.isEmpty {
                        Image(nsImage: state.image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: renderedSize.width, height: renderedSize.height)
                            // opaque: keeps edges solid instead of fading to see-through.
                            .blur(radius: AnnotationExporter.blurRadiusPoints * scale, opaque: true)
                            .mask(
                                ZStack(alignment: .topLeading) {
                                    Color.clear
                                        .frame(width: renderedSize.width, height: renderedSize.height)
                                    ForEach(Array(blurRectsImageSpace.enumerated()), id: \.offset) { _, rect in
                                        Rectangle()
                                            .frame(width: rect.width, height: rect.height)
                                            .offset(x: rect.minX, y: rect.minY)
                                    }
                                }
                            )
                            .offset(offset)
                            .allowsHitTesting(false)
                    }

                    // Canvas + gesture extend across the full surface so
                    // out-of-image arrows / text (Droplr convention) still
                    // work. Export clips to image bounds; strokes beyond
                    // are truncated there.
                    Canvas { context, _ in
                        drawAllStrokes(context: context, imageScale: scale, renderedOffset: offset)
                    }
                    .frame(width: surfaceSize.width, height: surfaceSize.height)
                    .gesture(dragGesture(imageScale: scale, offset: offset))

                    // Inline text editor — appears at the click point when
                    // the text tool is active and a stroke is in-progress.
                    // Replaces the toolbar text field so the toolbar layout
                    // doesn't jump every time a text annotation begins.
                    if state.currentTool == .text,
                       let pending = state.inProgress,
                       pending.tool == .text {
                        let pos = scaledPoint(pending.start, imageScale: scale, offset: offset)
                        let fontSize = max(28, pending.thickness * 6) * scale
                        TextField("", text: Binding(
                            get: { state.inProgress?.text ?? "" },
                            set: { state.updateInProgressText($0) }
                        ), onCommit: { state.commitText() })
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(pending.color)
                        .focused($inlineTextFieldFocused)
                        .frame(minWidth: 80, alignment: .leading)
                        .offset(x: pos.x, y: pos.y)
                        // `.id` keyed to the in-progress stroke ID so
                        // SwiftUI rebuilds the field for every new text —
                        // forces .onAppear / .task to fire fresh, which
                        // guarantees the focus assignment runs.
                        .id(pending.id)
                        .onAppear { inlineTextFieldFocused = true }
                        .task {
                            // Belt: yield once + reassign focus. SwiftUI
                            // sometimes fails to apply FocusState within
                            // the same runloop tick the view appeared in.
                            try? await Task.sleep(nanoseconds: 16_000_000)
                            inlineTextFieldFocused = true
                        }
                    }
                }
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .contentShape(Rectangle())
                // Pinch-to-zoom on trackpad. `.simultaneousGesture` lets
                // both the drag-to-annotate and pinch-to-zoom recognizers
                // run at the same time — if we used `.gesture`, one would
                // starve the other. Anchor the gesture to the base zoom
                // captured at start so magnification doesn't compound.
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if zoomAtGestureStart == nil {
                                zoomAtGestureStart = state.zoom
                            }
                            let proposed = (zoomAtGestureStart ?? 1.0) * value.magnification
                            state.zoom = min(
                                max(proposed, AnnotationState.minZoom),
                                AnnotationState.maxZoom
                            )
                        }
                        .onEnded { _ in
                            zoomAtGestureStart = nil
                        }
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Scale factor that fits the image into the container without cropping.
    /// Allows gentle upscaling (up to 1.5x) so small screenshots fill more
    /// of the editor — otherwise a 400px-wide capture sat in the middle of
    /// a 640px canvas with big margins, annotations hard to aim.
    private func fittingScale(containerSize: CGSize) -> CGFloat {
        guard state.imageSize.width > 0, state.imageSize.height > 0 else { return 1 }
        let wScale = containerSize.width / state.imageSize.width
        let hScale = containerSize.height / state.imageSize.height
        return min(wScale, hScale, 1.5)
    }

    /// Translate a view-space drag point to image-space coordinates.
    private func imagePoint(from viewPoint: CGPoint, scale: CGFloat, offset: CGSize) -> CGPoint {
        CGPoint(
            x: (viewPoint.x - offset.width) / scale,
            y: (viewPoint.y - offset.height) / scale
        )
    }

    private func dragGesture(imageScale: CGFloat, offset: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startPt = imagePoint(from: value.startLocation, scale: imageScale, offset: offset)
                let currentPt = imagePoint(from: value.location, scale: imageScale, offset: offset)

                if state.currentTool == .select {
                    // First tick of this gesture: hit-test. If something's
                    // selected, remember the anchor for incremental translate.
                    if translateLastPoint == nil {
                        let hit = state.selectStroke(at: startPt)
                        if hit {
                            state.beginTranslateSelected()
                        }
                        translateLastPoint = startPt
                    }
                    if let last = translateLastPoint, state.selectedStrokeID != nil {
                        let delta = CGSize(width: currentPt.x - last.x, height: currentPt.y - last.y)
                        state.translateSelected(by: delta)
                    }
                    translateLastPoint = currentPt
                } else if state.currentTool == .text {
                    // Text tool: every fresh mouse-down begins a new text.
                    // state.begin handles committing any in-progress text
                    // first. The latch ensures we don't begin again on
                    // subsequent onChanged ticks of the same drag.
                    if !gestureBegan {
                        state.begin(at: startPt)
                        gestureBegan = true
                    }
                } else {
                    // Shape tools (arrow/rect/etc.): begin once on first
                    // mouse-down, then extend on each onChanged tick.
                    if !gestureBegan {
                        state.begin(at: startPt)
                        gestureBegan = true
                    }
                    state.extend(to: currentPt)
                }
            }
            .onEnded { _ in
                gestureBegan = false
                if state.currentTool == .select {
                    translateLastPoint = nil
                } else {
                    state.commitDrag()
                }
            }
    }

    // MARK: - Stroke rendering

    private func drawAllStrokes(context: GraphicsContext, imageScale: CGFloat, renderedOffset: CGSize) {
        for stroke in state.committed {
            draw(stroke: stroke, context: context, imageScale: imageScale,
                 renderedOffset: renderedOffset, committed: true)
            if stroke.id == state.selectedStrokeID {
                drawSelectionOutline(for: stroke, context: context,
                                     imageScale: imageScale, renderedOffset: renderedOffset)
            }
        }
        if let pending = state.inProgress {
            draw(stroke: pending, context: context, imageScale: imageScale,
                 renderedOffset: renderedOffset, committed: false)
        }
    }

    private func drawSelectionOutline(
        for stroke: AnnotationStroke,
        context: GraphicsContext,
        imageScale: CGFloat,
        renderedOffset: CGSize
    ) {
        // Dashed rounded outline around the stroke's visual bounds,
        // inset slightly so it sits clear of the stroke itself. 1.5pt
        // line, 5/3 dash — matches Excalidraw's selection style.
        let bounds = scaledRect(
            stroke.visualBounds(), imageScale: imageScale, offset: renderedOffset
        ).insetBy(dx: -3, dy: -3)
        context.stroke(
            Path(roundedRect: bounds, cornerRadius: 4),
            with: .color(AppColors.bronze),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        )
    }

    private func draw(stroke: AnnotationStroke, context: GraphicsContext, imageScale: CGFloat,
                      renderedOffset: CGSize, committed: Bool) {
        let startPt = scaledPoint(stroke.start, imageScale: imageScale, offset: renderedOffset)
        let endPt = scaledPoint(stroke.end, imageScale: imageScale, offset: renderedOffset)
        let thickness = max(1, stroke.thickness * imageScale)
        let color = stroke.color
        let rect = scaledRect(stroke.rect, imageScale: imageScale, offset: renderedOffset)

        switch stroke.tool {
        case .select:
            return // not a drawable tool
        case .arrow:
            drawArrow(from: startPt, to: endPt, color: color, thickness: thickness, context: context)
        case .rectangle:
            context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color), lineWidth: thickness)
        case .ellipse:
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: thickness)
        case .highlight:
            context.fill(Path(rect), with: .color(color.opacity(0.35)))
        case .blur:
            // Real blur preview comes from the masked .blur(radius:) layer
            // in the canvas's parent ZStack — see AnnotationCanvas.body.
            // Here we only draw a faint outline during the active drag so
            // the user sees the live region boundary without the blurred
            // image obscuring its own edges.
            if !committed {
                context.stroke(Path(rect), with: .color(.white.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        case .redact:
            // Solid fill over the region — content underneath is permanently
            // obscured at export. In-progress draw shows the same fill plus
            // a dashed outline so the user sees the live edit boundary.
            context.fill(Path(rect), with: .color(color))
            if !committed {
                context.stroke(Path(rect), with: .color(.white.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        case .text:
            // Default stroke.thickness is 4 → old formula gave 14pt text,
            // unreadable on a screenshot. Floor at 28pt, scale with
            // thickness for user control.
            let fontSize = max(28, stroke.thickness * 6) * imageScale
            let textToShow = stroke.text.isEmpty ? "Type…" : stroke.text
            context.draw(
                Text(textToShow)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(color),
                at: startPt,
                anchor: .topLeading
            )
        case .number:
            let size = max(22, stroke.thickness * 5) * imageScale
            let circle = CGRect(x: startPt.x - size / 2, y: startPt.y - size / 2, width: size, height: size)
            context.fill(Path(ellipseIn: circle), with: .color(color))
            context.draw(
                Text("\(stroke.stepIndex ?? 0)")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundColor(.white),
                at: startPt
            )
        }
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, color: Color, thickness: CGFloat, context: GraphicsContext) {
        var line = Path()
        line.move(to: a)
        line.addLine(to: b)
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round))

        // Arrowhead
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 2 else { return }
        let ux = dx / length
        let uy = dy / length
        let headLen = max(12, thickness * 3.5)
        let spread = max(6, thickness * 2)

        let left = CGPoint(
            x: b.x - headLen * ux + spread * -uy,
            y: b.y - headLen * uy + spread * ux
        )
        let right = CGPoint(
            x: b.x - headLen * ux - spread * -uy,
            y: b.y - headLen * uy - spread * ux
        )
        var head = Path()
        head.move(to: b)
        head.addLine(to: left)
        head.addLine(to: right)
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    // MARK: - Coordinate helpers

    /// Convert an image-space point (y-down origin at image top-left) to a
    /// Canvas-space point (y-down origin at Canvas top-left). The Canvas
    /// covers the full container; the image is centered via `offset`, so we
    /// shift by the centering offset. No Y flip — SwiftUI Canvas and drag
    /// gestures are both y-DOWN. The earlier appearance of "Y inverted" was
    /// the offset math: imagePoint used to *subtract* offset from drag
    /// coords while the Canvas had already been .offset()'d, producing a
    /// doubled shift that made annotations land far from the cursor.
    private func scaledPoint(_ p: CGPoint, imageScale: CGFloat, offset: CGSize) -> CGPoint {
        CGPoint(
            x: p.x * imageScale + offset.width,
            y: p.y * imageScale + offset.height
        )
    }

    private func scaledRect(_ r: CGRect, imageScale: CGFloat, offset: CGSize) -> CGRect {
        CGRect(
            x: r.minX * imageScale + offset.width,
            y: r.minY * imageScale + offset.height,
            width: r.width * imageScale,
            height: r.height * imageScale
        )
    }

    /// Image-space rects (NO surface offset) for every blur stroke. Used
    /// to build the mask of the live blur preview. The blurred Image's
    /// `.offset(offset)` runs AFTER `.mask`, so the mask coordinates have
    /// to be in the local coord space of the unoffset image — adding the
    /// offset here would double-offset the visible blur region.
    private func scaledBlurRectsImageSpace(imageScale: CGFloat) -> [CGRect] {
        var rects: [CGRect] = []
        for stroke in state.committed where stroke.tool == .blur {
            rects.append(scaledRectImageSpace(stroke.rect, imageScale: imageScale))
        }
        if let pending = state.inProgress, pending.tool == .blur {
            rects.append(scaledRectImageSpace(pending.rect, imageScale: imageScale))
        }
        if !rects.isEmpty && AppSettings.shared.debugTranscripts {
            let summary = rects.map { String(format: "(%.0f,%.0f %.0fx%.0f)", $0.minX, $0.minY, $0.width, $0.height) }.joined(separator: " ")
            Logger.shared.log("annotation blur preview rects (image-space, scale=\(String(format: "%.2f", imageScale))): \(summary)")
        }
        return rects
    }

    private func scaledRectImageSpace(_ r: CGRect, imageScale: CGFloat) -> CGRect {
        CGRect(
            x: r.minX * imageScale,
            y: r.minY * imageScale,
            width: r.width * imageScale,
            height: r.height * imageScale
        )
    }
}
