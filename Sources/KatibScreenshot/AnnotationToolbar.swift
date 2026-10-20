import SwiftUI
import AppKit
import KatibCore

/// Tool palette + color + thickness + undo/clear + text entry for the
/// annotation window. Lives above the canvas.
@MainActor
struct AnnotationToolbar: View {
    @ObservedObject var state: AnnotationState

    private let colorPalette: [Color] = [
        AppColors.bronze,
        .red,
        .orange,
        .yellow,
        .green,
        .blue,
        .purple,
        .black,
        .white
    ]

    var body: some View {
        HStack(spacing: 12) {
            toolsCluster
            Divider().frame(height: 20)
            colorsCluster
            // Thickness slider removed — Asif doesn't tune it. Default
            // thickness (4) bakes in for every new stroke. Re-add by
            // putting `thicknessSlider` back here if needed.
            Spacer()
            actionsCluster
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var toolsCluster: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationTool.toolbarVisible) { tool in
                Button {
                    state.currentTool = tool
                    // Switching away from Select clears the selection so
                    // the dashed outline disappears — matches Excalidraw /
                    // tldraw: active tool and selected element shouldn't
                    // both persist visually.
                    if tool != .select {
                        state.selectedStrokeID = nil
                    }
                } label: {
                    Image(systemName: tool.symbolName)
                        .frame(width: 24, height: 24)
                        .background(
                            state.currentTool == tool
                            ? AppColors.bronze.opacity(0.2)
                            : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
                .help(tool.displayName)
                .accessibilityLabel(tool.displayName)
            }
        }
    }

    private var colorsCluster: some View {
        HStack(spacing: 4) {
            ForEach(Array(colorPalette.enumerated()), id: \.offset) { _, color in
                Button {
                    state.currentColor = color
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(color == state.currentColor ? Color.primary : Color.clear, lineWidth: 2)
                                .padding(-2)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color")
            }
        }
    }

    private var thicknessSlider: some View {
        HStack(spacing: 4) {
            Image(systemName: "lineweight")
                .foregroundColor(.secondary)
                .font(.caption2)
            Slider(value: $state.currentThickness, in: 1...16)
                .frame(width: 80)
        }
    }

    @ViewBuilder
    private var actionsCluster: some View {
        // Text input is now an inline field on the canvas at the click
        // point — see AnnotationCanvas. Removing the toolbar text field
        // means the toolbar's layout doesn't shift when text is being
        // entered, which fixes the "UI jars" feedback.
        Button {
            state.undo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .help("Undo")
        .keyboardShortcut("z", modifiers: .command)

        Button {
            // Confirm before nuking annotations mid-edit. Same shape as
            // the clipboard-clear guard — a stray click on the trash
            // icon shouldn't silently destroy work. If no annotations
            // exist there's nothing to confirm.
            guard !state.committed.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Clear all annotations?"
            alert.informativeText = "Removes \(state.committed.count) annotation\(state.committed.count == 1 ? "" : "s"). Undo will still work."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                state.reset()
            }
        } label: {
            Image(systemName: "trash")
        }
        .help("Clear all annotations")
    }
}
