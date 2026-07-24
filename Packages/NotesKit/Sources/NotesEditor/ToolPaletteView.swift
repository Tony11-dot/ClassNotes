import ClassMateTheme
import NotesDesignSystem
import SwiftUI

/// The floating glass tool palette: draggable, snaps to the left/right screen
/// edge, and morphs its glass with the ink-options popover.
struct ToolPaletteView: View {
    @Environment(\.theme) private var theme

    @Bindable var toolState: ToolState
    let tracker: ActiveCanvasTracker

    @State private var center: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var showInkOptions = false
    @Namespace private var glassNamespace

    private static let edgeInset: CGFloat = 44
    private static let paletteSize = CGSize(width: 64, height: 396)

    var body: some View {
        GeometryReader { geo in
            palette
                .position(center ?? defaultCenter(in: geo.size))
                .gesture(dragGesture(in: geo.size))
                .animation(.spring(duration: 0.35), value: center)
        }
        .allowsHitTesting(true)
    }

    private var palette: some View {
        GlassEffectContainer {
            VStack(spacing: 2) {
                ForEach(ToolState.Tool.allCases) { tool in
                    DSGlassIconButton(
                        tool.displayName,
                        systemImage: tool.symbolName,
                        isActive: toolState.tool == tool
                    ) {
                        toolState.select(tool)
                    }
                }

                Divider()
                    .frame(width: 28)
                    .overlay(theme.separator.color)
                    .padding(.vertical, 4)

                DSGlassIconButton("Ink options", systemImage: "circle.hexagongrid") {
                    showInkOptions = true
                }
                DSGlassIconButton("Undo", systemImage: "arrow.uturn.backward") {
                    tracker.activeCanvas?.undoManager?.undo()
                }
                DSGlassIconButton("Redo", systemImage: "arrow.uturn.forward") {
                    tracker.activeCanvas?.undoManager?.redo()
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .dsGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous), interactive: true)
            .glassEffectID("tool-palette", in: glassNamespace)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
        .popover(isPresented: $showInkOptions, arrowEdge: .trailing) {
            InkOptionsView(toolState: toolState)
                .presentationCompactAdaptation(.popover)
        }
        .frame(width: Self.paletteSize.width)
    }

    private func defaultCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - Self.edgeInset - Self.paletteSize.width / 2, y: size.height / 2)
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? center ?? defaultCenter(in: size)
                dragStart = start
                center = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
            }
            .onEnded { _ in
                dragStart = nil
                guard let current = center else { return }
                let halfWidth = Self.paletteSize.width / 2
                let snappedX = current.x < size.width / 2
                    ? Self.edgeInset + halfWidth
                    : size.width - Self.edgeInset - halfWidth
                let halfHeight = Self.paletteSize.height / 2
                let clampedY = min(max(current.y, halfHeight + 16), size.height - halfHeight - 16)
                center = CGPoint(x: snappedX, y: clampedY)
            }
    }
}

/// Color + thickness options for the current tool, in a glass popover.
struct InkOptionsView: View {
    @Environment(\.theme) private var theme

    @Bindable var toolState: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(toolState.tool.displayName)
                .font(.headline)
                .foregroundStyle(theme.ink.color)

            if toolState.tool == .pen || toolState.tool == .highlighter {
                swatches
                thickness
            } else {
                Text(
                    toolState.tool == .eraser
                        ? "Erases whole strokes. Undo brings them back."
                        : "Circle strokes to select, then drag to move them."
                )
                .font(.subheadline)
                .foregroundStyle(theme.inkSecondary.color)
                .frame(maxWidth: 220)
            }
        }
        .padding(18)
        .background(theme.surfaceRaised.color)
    }

    private var swatches: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 8)],
            spacing: 8
        ) {
            ForEach(toolState.inkPalette(theme: theme).map(\.hexString), id: \.self) { hex in
                swatchCell(hex)
            }
        }
        .frame(width: 220)
    }

    private func swatchCell(_ hex: String) -> some View {
        let swatch = ThemeColor(hex: hex) ?? theme.ink
        let isSelected = toolState.currentColor(theme: theme).hexString == hex
        return Button {
            toolState.setCurrentColor(swatch)
        } label: {
            Circle()
                .fill(swatch.color)
                .frame(width: 30, height: 30)
                .overlay {
                    Circle().strokeBorder(theme.separator.color, lineWidth: 0.5)
                    if isSelected {
                        Circle().strokeBorder(theme.accent.color, lineWidth: 2.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ink color \(hex)")
    }

    private var thickness: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Thickness — \(Int(toolState.currentWidth.rounded())) pt")
                .font(.subheadline)
                .foregroundStyle(theme.inkSecondary.color)
            Slider(
                value: Binding(
                    get: { toolState.currentWidth },
                    set: { toolState.currentWidth = $0 }
                ),
                in: toolState.tool == .highlighter ? 6...30 : 1...12
            )
            .frame(width: 220)
        }
    }
}
