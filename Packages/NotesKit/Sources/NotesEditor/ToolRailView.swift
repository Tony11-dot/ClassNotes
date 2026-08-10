import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// The editor's floating tool rail: draggable, snaps to the left/right edge.
///
/// Two halves, top to bottom:
/// - **Modes and actions** — write, tape, text box, photo, file, voice note, the
///   page manager, and the real-time beautification switch.
/// - **The pen tray** — every instrument in `PenLibrary` plus the eraser and the
///   ruler. The selected instrument lifts out of the rail; tapping it a second
///   time opens its settings, exactly like picking a pen up off a desk and then
///   inspecting it.
/// - **NOVA**, at the foot.
struct ToolRailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppServices.self) private var services

    @Bindable var toolState: ToolState
    let model: NotebookEditorModel
    let tracker: ActiveCanvasTracker

    @Binding var rulerVisible: Bool
    @Binding var showPages: Bool
    let onPhoto: () -> Void
    let onFile: () -> Void
    let onRecord: () -> Void
    let onBeautifyNow: () -> Void
    let onNova: () -> Void
    let onTapeVisibility: (Bool) -> Void

    @State private var center: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var panel: Panel?
    @Namespace private var glassNamespace

    enum Panel: Hashable {
        case pen(String)
        case eraser
        case tape
        case text
        case beautify
        case pageSettings
    }

    private static let edgeInset: CGFloat = 30
    private static let railWidth: CGFloat = 68
    /// The instruments are drawn as objects, not icons, so they need the room to
    /// show a clip, a ferrule, a nib. Below about this size the detail turns into
    /// texture and every pen starts to look like the same coloured stick.
    private static let glyphWidth: CGFloat = 56
    private static let glyphHeight: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            rail
                .position(center ?? defaultCenter(in: geo.size))
                .gesture(dragGesture(in: geo.size))
        }
    }

    private var rail: some View {
        GlassEffectContainer {
            VStack(spacing: 2) {
                modeButtons
                divider
                penTray
                divider
                DSGlassIconButton("Ask NOVA", systemImage: "sparkles") { onNova() }
                // The page owns its undo stack (`PageCanvasView.pageUndoManager`),
                // so these reach the same manager PencilKit registers into.
                DSGlassIconButton("Undo", systemImage: "arrow.uturn.backward") {
                    tracker.undo()
                }
                .disabled(!tracker.canUndo)
                .opacity(tracker.canUndo ? 1 : 0.35)
                DSGlassIconButton("Redo", systemImage: "arrow.uturn.forward") {
                    tracker.redo()
                }
                .disabled(!tracker.canRedo)
                .opacity(tracker.canRedo ? 1 : 0.35)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 5)
            .dsGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: true)
            .glassEffectID("tool-rail", in: glassNamespace)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .frame(width: Self.railWidth)
    }

    // MARK: - Modes

    @ViewBuilder
    private var modeButtons: some View {
        // Write — the headline control, filled when active like the screenshot.
        Button {
            _ = toolState.selectPen(toolState.pen)
        } label: {
            Image(systemName: "pencil")
                .font(.dsSystem(size: 18, weight: .semibold))
                .foregroundStyle(
                    toolState.tool == .pen
                        ? theme.contrastingInk(on: theme.accent).color
                        : theme.ink.color
                )
                .frame(width: 40, height: 40)
                .background {
                    if toolState.tool == .pen { Circle().fill(theme.accent.color) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Write")
        .padding(.bottom, 2)

        railButton("Tape", systemImage: "square.on.square.dashed", isActive: toolState.tool == .tape) {
            toolState.select(.tape)
            panel = .tape
        }
        .popover(isPresented: binding(.tape), arrowEdge: .leading) {
            TapePanel(toolState: toolState, onVisibility: onTapeVisibility)
                .presentationCompactAdaptation(.popover)
        }

        railButton("Voice note", systemImage: "mic") { onRecord() }
        railButton("Photo", systemImage: "photo") { onPhoto() }

        railButton("Text box", systemImage: "textformat", isActive: toolState.tool == .text) {
            toolState.select(.text)
            panel = .text
        }
        .popover(isPresented: binding(.text), arrowEdge: .leading) {
            TextBoxPanel(toolState: toolState)
                .presentationCompactAdaptation(.popover)
        }

        railButton("File", systemImage: "paperclip") { onFile() }
        railButton("Pages", systemImage: "book", isActive: showPages) { showPages.toggle() }

        beautifyButton
    }

    /// The ✨ switch: a tap opens its settings, a long press flips it on/off.
    private var beautifyButton: some View {
        Button {
            panel = .beautify
        } label: {
            VStack(spacing: -2) {
                Image(systemName: "wand.and.sparkles")
                    .font(.dsSystem(size: 16, weight: .medium))
                Text(toolState.beautify.isEnabled ? "ON" : "OFF")
                    .font(.dsSystem(size: 8, weight: .heavy))
            }
            .foregroundStyle(toolState.beautify.isEnabled ? theme.accent.color : theme.inkSecondary.color)
            .frame(width: 44, height: 42)
            .background {
                if toolState.beautify.isEnabled { Circle().fill(theme.accentMuted.color) }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Real-time handwriting beautification")
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                toolState.beautify.isEnabled.toggle()
            }
        )
        .popover(isPresented: binding(.beautify), arrowEdge: .leading) {
            BeautifyPanel(toolState: toolState, onBeautifyNow: onBeautifyNow)
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Pen tray

    private var penTray: some View {
        VStack(spacing: 4) {
            ForEach(PenLibrary.all) { preset in
                trayItem(preset)
            }
            eraserItem
            // Fill takes the colour the pen is holding, so picking a colour and
            // filling with it is one idea, not two.
            railButton("Fill", systemImage: "drop.fill", isActive: toolState.tool == .fill) {
                toolState.select(.fill)
                panel = nil
            }
            railButton("Select", systemImage: "lasso", isActive: toolState.tool == .lasso) {
                toolState.select(.lasso)
                panel = nil
            }
            railButton("Ruler", systemImage: "ruler", isActive: rulerVisible) {
                rulerVisible.toggle()
            }
            railButton("Move things", systemImage: "hand.point.up.left", isActive: toolState.tool == .hand) {
                toolState.select(.hand)
                panel = nil
            }
        }
    }

    private func trayItem(_ preset: PenPreset) -> some View {
        let isSelected = toolState.tool == .pen && toolState.penPresetID == preset.id
        let settings = toolState.settings(for: preset)
        let color = settings.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink
        return Button {
            // First tap picks the pen up; tapping the pen already in hand opens
            // its settings.
            let wasInHand = toolState.selectPen(preset)
            panel = wasInHand ? .pen(preset.id) : nil
            // The highlighter is the reading tool: picking it up clears the screen
            // down to the page itself (see ToolState.focusMode). The panel still
            // opens on the second tap, so it stays tunable.
            if preset.isHighlighter, !wasInHand {
                toolState.focusMode = true
            }
        } label: {
            PenGlyphView(
                preset: preset,
                color: color.withAlpha(max(0.35, settings.concentration)),
                isSelected: isSelected
            )
            .frame(width: Self.glyphWidth, height: Self.glyphHeight)
            // The instrument in your hand sits on a lit plate, pulled out of the
            // rail toward the page and standing a little above its neighbours —
            // the same read as a pen lifted off a desk.
            // The instrument in your hand sits on a lit plate, pulled out of the
            // rail toward the page — the same read as a pen lifted off a desk.
            //
            // The plate stays INSIDE the slot the row already reserves
            // (`glyphHeight + 10`). It used to bleed 5 pt into the rows above and
            // below and rely on `.zIndex` to win the overlap — but that zIndex sat
            // under the same `.animation(value: isSelected)` as everything else, so
            // selecting a pen re-sorted the stack mid-spring and the glyph flicked
            // behind its neighbours and back. Not overlapping at all is the fix:
            // there is no z-order left to get wrong.
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.accentMuted.color)
                        .padding(.vertical, -2)
                        .padding(.horizontal, -6)
                        .shadow(color: theme.accent.withAlpha(0.28).color, radius: 5, y: 2)
                }
            }
            .offset(x: isSelected ? 9 : 0)
            .scaleEffect(isSelected ? 1.12 : 1, anchor: .leading)
            .frame(width: Self.glyphWidth, height: Self.glyphHeight + 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3, bounce: 0.28), value: isSelected)
        .accessibilityLabel(preset.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .popover(isPresented: binding(.pen(preset.id)), arrowEdge: .leading) {
            PenSettingsPanel(toolState: toolState, preset: preset)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var eraserItem: some View {
        railButton("Eraser", systemImage: "eraser", isActive: toolState.tool == .eraser) {
            if toolState.tool == .eraser {
                panel = .eraser
            } else {
                toolState.select(.eraser)
            }
        }
        .popover(isPresented: binding(.eraser), arrowEdge: .leading) {
            EraserPanel(toolState: toolState)
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Plumbing

    private func railButton(
        _ label: String, systemImage: String, isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.dsSystem(size: 16, weight: .medium))
                .foregroundStyle(isActive ? theme.accent.color : theme.ink.color)
                .frame(width: 44, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .background {
            if isActive { Circle().fill(theme.accentMuted.color).frame(width: 38, height: 38) }
        }
    }

    private var divider: some View {
        Divider().frame(width: 26).overlay(theme.separator.color).padding(.vertical, 3)
    }

    private func binding(_ which: Panel) -> Binding<Bool> {
        Binding(get: { panel == which }, set: { panel = $0 ? which : nil })
    }

    // MARK: - Positioning

    private func defaultCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: Self.edgeInset + Self.railWidth / 2, y: size.height / 2)
    }

    /// Dragging the rail. Every reported position is applied IMMEDIATELY and
    /// unanimated, so the rail stays under the finger; only the release — where
    /// the rail flies to the nearer edge — is animated.
    ///
    /// A blanket `.animation(_:value: center)` on the rail animated the drag
    /// itself: each `onChanged` started a fresh 0.32 s spring toward the finger,
    /// so the rail trailed the whole way and only caught up after the lift. That
    /// is what "it jumps to where the finger lifts" looks like.
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
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
                let clampedY = min(max(current.y, 260), max(260, size.height - 260))
                withAnimation(.spring(duration: 0.32)) {
                    center = CGPoint(x: snappedX, y: clampedY)
                }
            }
    }
}
