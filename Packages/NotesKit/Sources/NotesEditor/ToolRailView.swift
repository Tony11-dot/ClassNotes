import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// The editor's floating tool rail: draggable, docks to whichever of the four
/// edges it's dropped nearest.
///
/// Moving it is two-stage, like picking a whole tray up versus nudging it: the
/// instant a drag begins, the rail collapses into a small circular chip (the
/// same idea as `NovaBubble`) that follows the finger, so a hand mid-drag is
/// never trying to steer something the size of the whole rail. Letting go
/// leaves it AS that chip — tapping it is what expands it back out, laid out
/// for wherever it landed: a column when docked to the left/right edge, a row
/// when docked to the top/bottom (`RailFlowLayout`), wrapping into more
/// columns/rows on its own rather than running off the edge of the screen.
///
/// Expanded, two halves, top to bottom (or leading to trailing, docked
/// horizontally):
/// - **Modes and actions** — write, tape, text box, photo, file, voice note, the
///   page manager, and the real-time beautification switch.
/// - **The pen tray** — every instrument in `PenLibrary` plus the eraser and the
///   ruler. The selected instrument lifts out of the rail; tapping it a second
///   time opens its settings, exactly like picking a pen up off a desk and then
///   inspecting it.
/// - **NOVA, undo and redo**, at the foot.
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
    /// Bumped by the editor when something outside the rail asks for the current
    /// pen's panel — a Pencil squeeze mapped to "show colours".
    var openPenPanel: UUID?

    /// The chip's position while collapsed, and the expanded rail's own
    /// along-the-edge anchor — see `expandedCenter`.
    @State private var center: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var panel: Panel?
    /// Starts collapsed the first time the rail is ever dropped near an edge,
    /// same as the chip a fresh drag turns it into — an already-expanded rail
    /// sitting over the page before the user has touched it at all would be
    /// exactly the "covering the hand" problem collapsing exists to solve.
    @State private var isCollapsed = true

    enum Panel: Hashable {
        case pen(String)
        case eraser
        case tape
        case text
        case codeBlock
        case functionPlot
        case beautify
        case pageSettings
    }

    private static let edgeInset: CGFloat = 30
    private static let railWidth: CGFloat = 84
    /// The instruments are drawn as objects, not icons, so they need the room to
    /// show a clip, a ferrule, a nib. Below about this size the detail turns into
    /// texture and every pen starts to look like the same coloured stick.
    private static let glyphWidth: CGFloat = 68
    private static let glyphHeight: CGFloat = 30
    /// The collapsed chip, matching `NovaBubble`'s own size so the two floating
    /// controls in the editor read as one family.
    private static let chipSize: CGFloat = 56
    /// Assumed half-extent of the EXPANDED rail along its own short axis (its
    /// width when docked left/right, its height when docked top/bottom) —
    /// `RailFlowLayout` only wraps into a second column/row on an unusually
    /// short or narrow window, so this covers the common single-column/row
    /// case exactly and is off by at most one wrap's worth otherwise, never
    /// enough to make anything unreachable.
    private static let expandedShortHalfExtent: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let edge = nearestEdge(of: center ?? defaultCenter(in: geo.size), in: geo.size)
            Group {
                if isCollapsed {
                    chip
                        .position(center ?? defaultCenter(in: geo.size))
                        .gesture(dragGesture(in: geo.size))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    expandedRail(edge: edge, in: geo.size)
                        .position(expandedCenter(edge: edge, in: geo.size))
                        .gesture(dragGesture(in: geo.size))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            // Same spring NOVA's own sidebar slides in and out with, so both
            // panels in the editor feel like one consistent piece of motion.
            .animation(.spring(duration: 0.3), value: isCollapsed)
        }
        .onChange(of: openPenPanel) { _, request in
            guard request != nil else { return }
            toolState.select(.pen)
            panel = .pen(toolState.penPresetID)
        }
    }

    /// The collapsed chip: a tap expands the rail back out; a drag (see
    /// `dragGesture`) moves it and re-docks it on release.
    private var chip: some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { isCollapsed = false }
        } label: {
            ZStack {
                Circle()
                    .fill(theme.accent.color)
                    .shadow(color: .black.opacity(0.26), radius: 12, y: 5)
                Image(systemName: "pencil.and.ruler.fill")
                    .font(.dsSystem(size: 21, weight: .semibold))
                    .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
            }
            .frame(width: Self.chipSize, height: Self.chipSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show tools")
    }

    // The rail is ONE piece of glass, so it needs no `GlassEffectContainer` (that
    // exists to merge and morph several) and it is not `interactive` (that is for
    // a control that reacts to its own touches — here it re-rendered the whole
    // rail's material on every tap on a pen).
    ///
    /// `RailFlowLayout` wraps the SAME flat run of buttons into columns when
    /// docked left/right and rows when docked top/bottom — a plain `VStack`
    /// only ever suited the column case, and a fixed-length `HStack` of every
    /// button in the rail is wider than any iPad screen. The budget passed to
    /// it (`maxHeight` for a column, `maxWidth` for a row) is what tells it
    /// when to actually wrap — the editor's own available space minus enough
    /// margin that a full-height/width rail never touches the opposite edge.
    private func expandedRail(edge: Edge, in size: CGSize) -> some View {
        let axis: Axis = (edge == .top || edge == .bottom) ? .horizontal : .vertical
        let budget = (axis == .vertical ? size.height : size.width) - Self.edgeInset * 2
        return RailFlowLayout(axis: axis, spacing: 6) {
            modeButtons
            penTray
            DSGlassIconButton("Ask NOVA", systemImage: "sparkles") { onNova() }
            // The page owns its undo stack (`PageCanvasView.pageUndoManager`),
            // driven directly by the coordinator's own history — NOT by
            // PencilKit's registrations, which never reliably reach it (a
            // `PKCanvasView` inside SwiftUI is never first responder).
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
        .frame(
            maxWidth: axis == .vertical ? nil : budget,
            maxHeight: axis == .vertical ? budget : nil
        )
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .dsGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }

    // MARK: - Modes

    @ViewBuilder
    private var modeButtons: some View {
        // Write — the headline control, filled when active like the screenshot.
        Button {
            _ = toolState.selectPen(toolState.pen)
        } label: {
            Image(systemName: "pencil")
                .font(.dsSystem(size: 22, weight: .semibold))
                .foregroundStyle(
                    toolState.tool == .pen
                        ? theme.contrastingInk(on: theme.accent).color
                        : theme.ink.color
                )
                .frame(width: 48, height: 48)
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

        railButton(
            "Code block", systemImage: "chevron.left.forwardslash.chevron.right",
            isActive: toolState.tool == .codeBlock
        ) {
            toolState.select(.codeBlock)
            panel = .codeBlock
        }
        .popover(isPresented: binding(.codeBlock), arrowEdge: .leading) {
            CodeBlockPanel(toolState: toolState)
                .presentationCompactAdaptation(.popover)
        }

        railButton(
            "Function plot", systemImage: "function",
            isActive: toolState.tool == .functionPlot
        ) {
            toolState.select(.functionPlot)
            panel = .functionPlot
        }
        // A big settings sheet, not a small popover: picking the tool goes
        // straight to configuring every setting — axis count, curve type,
        // expressions, axis names/units/ticks, colours — with a Create button
        // at the bottom, rather than waiting for a tap on the page to drop a
        // blank block first. The block appears already fully configured,
        // centred on the page; from there it's just dragged/resized into
        // place like any other element.
        .sheet(isPresented: binding(.functionPlot), onDismiss: { toolState.select(.hand) }) {
            FunctionPlotSettingsSheet(
                isNew: true,
                mode: toolState.functionPlotMode, expression: "", secondary: nil, tertiary: nil,
                window: toolState.functionPlotWindow,
                axisXLabel: nil, axisYLabel: nil, axisZLabel: nil,
                axisXUnit: nil, axisYUnit: nil, axisZUnit: nil,
                axisXDisplay: AxisDisplay(label: "X"), axisYDisplay: AxisDisplay(label: "Y"),
                axisZDisplay: AxisDisplay(label: "Z"),
                lineColorHex: toolState.functionPlotLineColorHex ?? FunctionPlotSettings.defaultLineHex,
                backgroundColorHex: toolState.functionPlotBackgroundColorHex ?? FunctionPlotSettings.defaultBackgroundHex,
                transparentBackground: toolState.functionPlotTransparentBackground,
                cornerRadius: toolState.functionPlotCornerRadius,
                onCommit: { draft, lineHex, backgroundHex, cornerRadius, transparent in
                    guard let pageID = model.focusedPageID else { panel = nil; return }
                    let center = model.page(pageID).map {
                        CGPoint(x: $0.logicalSize.width / 2, y: $0.logicalSize.height / 2)
                    } ?? .zero
                    Task {
                        await model.insertFunctionPlot(
                            at: center, on: pageID, draft: draft,
                            lineColorHex: lineHex, backgroundColorHex: backgroundHex,
                            cornerRadius: cornerRadius, transparentBackground: transparent
                        )
                    }
                    panel = nil
                }
            )
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
                    .font(.dsSystem(size: 19, weight: .medium))
                Text(toolState.beautify.isEnabled ? "ON" : "OFF")
                    .font(.dsSystem(size: 9, weight: .heavy))
            }
            .foregroundStyle(toolState.beautify.isEnabled ? theme.accent.color : theme.inkSecondary.color)
            .frame(width: 54, height: 50)
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
        VStack(spacing: 5) {
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
            // The instrument in your hand sits on a lit plate — the same read as a
            // pen lifted off a desk.
            //
            // Everything about that read stays INSIDE the rail's glass. The plate
            // stays inside the slot the row reserves (`glyphHeight + 10`) so there
            // is no vertical overlap to z-sort, and the selected glyph no longer
            // slides out past the glass's right edge: it used to `offset(x: 9)` and
            // scale from `.leading`, which pushed it some 17 pt beyond the rounded
            // rect. A view crossing the boundary of a `glassEffect` gets promoted
            // out of the glass layer, and the promotion lands a frame late — which
            // is the pen appearing to sit UNDER the rail and then snap above it
            // partway through the spring. Contained, there is no promotion at all.
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.accentMuted.color)
                        .padding(.vertical, -2)
                        .padding(.horizontal, -1)
                        .shadow(color: theme.accent.withAlpha(0.28).color, radius: 5, y: 2)
                }
            }
            .scaleEffect(isSelected ? 1.07 : 1)
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
                .font(.dsSystem(size: 19, weight: .medium))
                .foregroundStyle(isActive ? theme.accent.color : theme.ink.color)
                .frame(width: 54, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .background {
            if isActive { Circle().fill(theme.accentMuted.color).frame(width: 46, height: 46) }
        }
    }

    private func binding(_ which: Panel) -> Binding<Bool> {
        Binding(get: { panel == which }, set: { panel = $0 ? which : nil })
    }

    // MARK: - Positioning

    private func defaultCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: Self.edgeInset + Self.chipSize / 2, y: size.height / 2)
    }

    /// Which of the four edges `point` sits nearest — this is both which edge
    /// the chip docks to AND, expanded, which axis `RailFlowLayout` lays the
    /// rail out on (a column for leading/trailing, a row for top/bottom).
    private func nearestEdge(of point: CGPoint, in size: CGSize) -> Edge {
        let distances: [(Edge, CGFloat)] = [
            (.leading, point.x), (.trailing, size.width - point.x),
            (.top, point.y), (.bottom, size.height - point.y)
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .leading
    }

    /// Keeps the along-edge coordinate clear of the corners — the expanded
    /// rail is bigger than the chip it grew from, and a chip dropped right in
    /// a corner would expand with part of itself pushed off screen.
    private func clampAlong(edge: Edge, value: CGPoint, in size: CGSize) -> CGPoint {
        let margin: CGFloat = 140
        switch edge {
        case .leading, .trailing:
            return CGPoint(x: value.x, y: min(max(value.y, margin), max(margin, size.height - margin)))
        case .top, .bottom:
            return CGPoint(x: min(max(value.x, margin), max(margin, size.width - margin)), y: value.y)
        }
    }

    /// The expanded rail's own centre: pinned out from its docked edge by
    /// `expandedShortHalfExtent`, at the same along-the-edge position the chip
    /// was left at.
    private func expandedCenter(edge: Edge, in size: CGSize) -> CGPoint {
        let along = clampAlong(edge: edge, value: center ?? defaultCenter(in: size), in: size)
        let half = Self.expandedShortHalfExtent
        switch edge {
        case .leading: return CGPoint(x: Self.edgeInset + half, y: along.y)
        case .trailing: return CGPoint(x: size.width - Self.edgeInset - half, y: along.y)
        case .top: return CGPoint(x: along.x, y: Self.edgeInset + half)
        case .bottom: return CGPoint(x: along.x, y: size.height - Self.edgeInset - half)
        }
    }

    /// Dragging the rail (as the chip, or the moment a drag begins on the
    /// expanded rail — see `body`). Every reported position is applied
    /// IMMEDIATELY and unanimated, so the chip stays under the finger; only
    /// the release — where it docks to the nearer edge — is animated.
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
                if !isCollapsed { isCollapsed = true }
                center = CGPoint(x: start.x + value.translation.width,
                                 y: start.y + value.translation.height)
            }
            .onEnded { _ in
                dragStart = nil
                guard let current = center else { return }
                let edge = nearestEdge(of: current, in: size)
                let half = Self.chipSize / 2
                let docked: CGPoint
                switch edge {
                case .leading: docked = CGPoint(x: Self.edgeInset + half, y: current.y)
                case .trailing: docked = CGPoint(x: size.width - Self.edgeInset - half, y: current.y)
                case .top: docked = CGPoint(x: current.x, y: Self.edgeInset + half)
                case .bottom: docked = CGPoint(x: current.x, y: size.height - Self.edgeInset - half)
                }
                withAnimation(.spring(duration: 0.32)) {
                    center = clampAlong(edge: edge, value: docked, in: size)
                }
            }
    }
}
