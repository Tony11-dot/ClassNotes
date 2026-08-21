import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// The editor's floating tool rail: FIXED to the leading edge, never dragged.
///
/// It used to be draggable and could be dropped on any of the four edges —
/// which meant it could also be dropped somewhere half off-screen, behind the
/// page manager, or simply forgotten about in a spot that didn't get found
/// again. There is now exactly one place it lives: pinned to the left edge,
/// vertically centred, where every tool has room to show. The only way to
/// change how much of it is on screen is the explicit hide control
/// (`hideButton`, the first thing in `expandedRail`) — tapping it collapses
/// the whole tray down to a small circular chip (the same idea as
/// `NovaBubble`); tapping the chip pops the FULL rail back out, always at
/// that same fixed spot, never wherever a previous drag happened to leave it.
///
/// Expanded, top to bottom:
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
            // ONE view, always mounted, for both the chip and the expanded
            // rail — cross-faded by opacity rather than swapped with
            // `if/else`, so collapsing/expanding is a plain spring rather than
            // a teardown-and-recreate of whatever's on screen.
            ZStack {
                expandedRail(in: geo.size)
                    .opacity(isCollapsed ? 0 : 1)
                    .allowsHitTesting(!isCollapsed)
                chip
                    .opacity(isCollapsed ? 1 : 0)
                    .allowsHitTesting(isCollapsed)
            }
            // Constrains hit-testing to roughly the size of whatever's
            // actually visible, rather than the union of both — the expanded
            // rail is much bigger than the chip, and without this a collapsed
            // chip would still accept touches from the dead space the
            // (invisible) full-size rail still occupies.
            .frame(width: isCollapsed ? Self.chipSize : nil, height: isCollapsed ? Self.chipSize : nil)
            .position(isCollapsed ? chipCenter(in: geo.size) : expandedCenter(in: geo.size))
        }
        .onChange(of: openPenPanel) { _, request in
            guard request != nil else { return }
            toolState.select(.pen)
            panel = .pen(toolState.penPresetID)
        }
    }

    /// The collapsed chip: a tap expands the rail back out, always at its one
    /// fixed spot (`expandedCenter`) — never wherever it happened to be last.
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

    /// The rail is ONE piece of glass, so it needs no `GlassEffectContainer`
    /// (that exists to merge and morph several) and it is not `interactive`
    /// (that is for a control that reacts to its own touches — here it
    /// re-rendered the whole rail's material on every tap on a pen).
    ///
    /// Always a column now that the rail is fixed to the leading edge —
    /// `RailFlowLayout` still owns the wrap, in case the tray ever grows
    /// taller than the screen has room for, but it only ever wraps into a
    /// second COLUMN, never a row.
    private func expandedRail(in size: CGSize) -> some View {
        let budget = size.height - Self.edgeInset * 2
        return RailFlowLayout(axis: .vertical, spacing: 6) {
            hideButton
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
        .frame(maxHeight: budget)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .dsGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }

    /// Collapses the rail back down to the chip. The explicit control the
    /// rail's own doc comment promises — dragging used to be the only way to
    /// tuck the rail away, and removing dragging without replacing it would
    /// have left no way to get the tools out from over the page at all.
    private var hideButton: some View {
        railButton("Hide tools", systemImage: "chevron.left") {
            withAnimation(.spring(duration: 0.3)) { isCollapsed = true }
        }
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

    /// `@ViewBuilder`, NOT a `VStack`: this used to be one, and it silently
    /// broke rendering of the WHOLE rail — not just the pen tray, the
    /// collapsed chip too, sitting right next to it in the same `ZStack`.
    /// `RailFlowLayout`'s `Subviews` flattens a bare run of buttons (like
    /// `modeButtons`) into one measured item per button, but stops at an
    /// explicit container — a `VStack` is handed over as ONE opaque subview,
    /// sized by its own internal layout rather than `RailFlowLayout`'s. Nine
    /// pen glyphs plus the eraser and four rail buttons stacked that way is
    /// tall enough that mixing it into the SAME flow as `modeButtons`
    /// produced a blank render for the entire `ToolRailView`, confirmed by
    /// rendering the real view off-screen and bisecting its content
    /// (`ToolRailRenderTests.swift`) — nothing about the failure showed up as
    /// a crash or a NaN in `RailFlowLayout`'s own arithmetic, just nothing
    /// painted. Flattening this into individual items, exactly like
    /// `modeButtons`, both fixes that and lets the tray actually wrap into a
    /// second column/row like the rest of the rail when docked top/bottom —
    /// which a `VStack` could never do regardless of this bug.
    @ViewBuilder
    private var penTray: some View {
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

    /// The collapsed chip's one fixed spot: the leading edge, vertically
    /// centred.
    private func chipCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: Self.edgeInset + Self.chipSize / 2, y: size.height / 2)
    }

    /// The expanded rail's one fixed spot: pinned out from the leading edge
    /// by `expandedShortHalfExtent`, same vertical centre as the chip — this
    /// is "that place of its" the rail always pops back out to, whatever was
    /// last open or closed.
    private func expandedCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: Self.edgeInset + Self.expandedShortHalfExtent, y: size.height / 2)
    }
}
