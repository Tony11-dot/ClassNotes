import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// The editor's floating tool rail: draggable, snaps to the left/right edge.
/// Each drawing tool (pen / marker / eraser) taps to select AND expands its
/// settings in a popover; ruler toggles the straight-edge; insert/record fire
/// actions; hand switches to object mode; page settings and the page manager
/// each open their own panel.
struct ToolRailView: View {
    @Environment(\.theme) private var theme

    @Bindable var toolState: ToolState
    let model: NotebookEditorModel
    let tracker: ActiveCanvasTracker

    @Binding var rulerVisible: Bool
    @Binding var showPages: Bool
    let onPhoto: () -> Void
    let onFile: () -> Void
    let onRecord: () -> Void
    let onBeautify: () -> Void

    @State private var center: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var panel: Panel?
    @Namespace private var glassNamespace

    enum Panel: Hashable { case pen, marker, eraser, pageSettings }

    private static let edgeInset: CGFloat = 30
    private static let railWidth: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            rail
                .position(center ?? defaultCenter(in: geo.size))
                .gesture(dragGesture(in: geo.size))
                .animation(.spring(duration: 0.32), value: center)
        }
    }

    private var rail: some View {
        GlassEffectContainer {
            VStack(spacing: 3) {
                toolButton(.pen, panel: .pen)
                toolButton(.marker, panel: .marker)
                toolButton(.eraser, panel: .eraser)

                divider

                DSGlassIconButton("Ruler", systemImage: "ruler", isActive: rulerVisible) {
                    rulerVisible.toggle()
                }

                divider

                DSGlassIconButton("Photo", systemImage: "photo") { onPhoto() }
                DSGlassIconButton("File", systemImage: "paperclip") { onFile() }
                DSGlassIconButton("Record", systemImage: "mic") { onRecord() }

                divider

                DSGlassIconButton("Hand", systemImage: ToolState.Tool.hand.symbolName,
                                  isActive: toolState.tool == .hand) {
                    toolState.select(.hand)
                    panel = nil
                }
                pageSettingsButton
                DSGlassIconButton("Pages", systemImage: "square.grid.2x2", isActive: showPages) {
                    showPages.toggle()
                }

                divider

                DSGlassIconButton("Undo", systemImage: "arrow.uturn.backward") {
                    tracker.activeCanvas?.undoManager?.undo()
                }
                DSGlassIconButton("Redo", systemImage: "arrow.uturn.forward") {
                    tracker.activeCanvas?.undoManager?.redo()
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .dsGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: true)
            .glassEffectID("tool-rail", in: glassNamespace)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .frame(width: Self.railWidth)
    }

    private var divider: some View {
        Divider().frame(width: 26).overlay(theme.separator.color).padding(.vertical, 2)
    }

    private func toolButton(_ tool: ToolState.Tool, panel which: Panel) -> some View {
        DSGlassIconButton(tool.displayName, systemImage: tool.symbolName, isActive: toolState.tool == tool) {
            toolState.select(tool)
            panel = which
        }
        .popover(isPresented: panelBinding(which), arrowEdge: .leading) {
            toolPanel(for: which)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var pageSettingsButton: some View {
        DSGlassIconButton("Page settings", systemImage: "slider.horizontal.3") {
            panel = .pageSettings
        }
        .popover(isPresented: panelBinding(.pageSettings), arrowEdge: .leading) {
            PageSettingsPanel(model: model)
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private func toolPanel(for which: Panel) -> some View {
        switch which {
        case .pen: PenPanel(toolState: toolState, onBeautify: onBeautify)
        case .marker: MarkerPanel(toolState: toolState)
        case .eraser: EraserPanel(toolState: toolState)
        case .pageSettings: PageSettingsPanel(model: model)
        }
    }

    private func panelBinding(_ which: Panel) -> Binding<Bool> {
        Binding(get: { panel == which }, set: { panel = $0 ? which : nil })
    }

    // MARK: - Positioning

    private func defaultCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: Self.edgeInset + Self.railWidth / 2, y: size.height / 2)
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? center ?? defaultCenter(in: size)
                dragStart = start
                center = CGPoint(x: start.x + value.translation.width,
                                 y: start.y + value.translation.height)
            }
            .onEnded { _ in
                dragStart = nil
                guard let current = center else { return }
                let half = Self.railWidth / 2
                let snappedX = current.x < size.width / 2
                    ? Self.edgeInset + half
                    : size.width - Self.edgeInset - half
                let clampedY = min(max(current.y, 180), size.height - 180)
                center = CGPoint(x: snappedX, y: clampedY)
            }
    }
}
