import ClassMateTheme
import NotesDesignSystem
import NotesModels
import QuickLook
import SwiftUI
import UIKit

/// Renders and edits everything layered over one page's ink: images, files,
/// links, voice notes, text boxes and sticky tape.
///
/// Elements are stored in the page's logical space and scaled to the displayed
/// size. Drag to move (live, 1:1); pinch to resize; press and hold for the
/// system context menu (the element lifts, the page blurs, the actions drop out
/// below it); tap a file or link to open it; tap a strip of tape to lift it; tap a
/// text box in text/move mode to type in it.
struct PageElementsLayer: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    let pageID: UUID
    let elements: [PageElement]
    let model: NotebookEditorModel
    /// Needed for the eraser: tape is an element, not ink, so the canvas's own
    /// eraser can never touch it — this layer has to do it.
    let toolState: ToolState
    /// Displayed page size in view points (from the parent GeometryReader).
    let displaySize: CGSize
    /// The page's logical size, so the scale is right for any paper size.
    let logicalSize: CGSize
    /// Elements only move/resize when the pencil isn't drawing.
    let allowsEditing: Bool
    /// The text box the keyboard is currently in, owned by the editor screen.
    @Binding var editingTextID: UUID?
    /// The element currently showing its resize handle, owned by the editor
    /// screen so both this layer's `belowInk`/`aboveInk` instances and the
    /// page's own background tap (which clears it) agree on the same value.
    /// `nil` for non-interactive render targets, same as `tracker`.
    var selectedElementID: Binding<UUID?> = .constant(nil)
    /// Which elements this instance renders, relative to the ink layer.
    var layer: Layer = .all
    /// So element edits (move, resize, erase, tape toggle) register a real undo
    /// step, the same way ink strokes and beautification already do. `nil` for
    /// non-interactive render targets (page snapshots for NOVA/export), which
    /// never fire these gestures in the first place.
    var tracker: ActiveCanvasTracker?

    /// Ink paints ABOVE non-tape elements (images, files, text, audio, links)
    /// so a stroke drawn over one is actually visible on top of it — tape
    /// stays above ink, because hiding what's underneath it is the entire
    /// point of tape. A caller that composites ink as its own separate layer
    /// (`EditorScreenPages.canvasStack`, `PageCompositeView`) renders one
    /// `PageElementsLayer` on each side of it; `.all` is for any caller that
    /// doesn't split ink out at all.
    enum Layer {
        case all, belowInk, aboveInk
    }

    /// Live drag translation for the element currently under the finger, so the
    /// bubble tracks the finger instead of jumping on release.
    @State private var dragOffset: CGSize = .zero
    @State private var draggingID: UUID?
    /// Live resize translation, from the corner handle. Same idea as
    /// `dragOffset`: the box grows/shrinks under the finger instead of only
    /// snapping to its new size on release.
    @State private var resizeDelta: CGSize = .zero
    @State private var resizingID: UUID?
    /// Strips already removed by the eraser gesture in flight, so one continuous
    /// scrub deletes each one exactly once.
    @State private var erasedElementIDs: Set<UUID> = []
    @State private var previewURL: URL?
    @FocusState private var textFieldFocused: Bool
    /// Which function-plot element is open in the big settings sheet — for
    /// BOTH a hold on an existing graph and (via `TextPlacementLayer`'s own
    /// commit) never a brand-new one, since creation goes through
    /// `ToolRailView`'s own sheet instead.
    @State private var editingFunctionPlotID: PageElement.ID?

    private var scale: CGFloat { displaySize.width / max(logicalSize.width, 1) }

    /// Smallest an element may shrink to, in logical points — matches the
    /// floor the pinch-resize path already enforces.
    private static let minimumElementSide: Double = 40

    /// Fills are never in here: their outlines are in absolute page
    /// coordinates and they belong underneath the ink, so `PageFillLayer`
    /// draws them below the canvas instead.
    private var visibleElements: [PageElement] {
        let nonFill = elements.filter { $0.kind != .fill }
        switch layer {
        case .all: return nonFill
        case .belowInk: return nonFill.filter { $0.kind != .tape && !$0.renderAboveInk }
        case .aboveInk: return nonFill.filter { $0.kind == .tape || $0.renderAboveInk }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleElements) { element in
                let live = draggingID == element.id ? dragOffset : .zero
                let (liveWidth, liveHeight) = resizedSize(for: element)
                elementView(element)
                    .frame(width: liveWidth * scale, height: liveHeight * scale)
                    .overlay(alignment: .bottomTrailing) {
                        // Pinching directly on the element still works (kept as
                        // a secondary path), but it's the same two-finger
                        // gesture the page itself uses to zoom, and the two
                        // compete. A dedicated single-finger handle can't
                        // collide with that, and it's the discoverable way to
                        // resize precisely — the whole reason resizing an
                        // element only ever seemed to work by accident.
                        if allowsEditing, element.kind != .tape, selectedElementID.wrappedValue == element.id {
                            resizeHandle(for: element)
                        }
                    }
                    .rotationEffect(.degrees(element.rotation))
                    .position(
                        x: (element.x + liveWidth / 2) * scale + live.width,
                        y: (element.y + liveHeight / 2) * scale + live.height
                    )
                    // Always live, regardless of which tool is selected: a finger
                    // never inks (`drawingPolicy = .pencilOnly`), so dragging an
                    // element by touch can never collide with drawing. Gating this
                    // on `allowsEditing` (the same switch that hides the resize
                    // handle) meant a photo or text box could only be picked up
                    // after switching away from the pen — which is not what "press
                    // and drag it" looks like from the user's side.
                    .gesture(dragGesture(for: element))
                    .simultaneousGesture(resizeGesture(for: element), including: gestureMask(for: element))
                    .onTapGesture { handleTap(element) }
                    // Erasing tape wins over lifting it, so a rubbed-out strip is
                    // gone rather than merely revealed.
                    .highPriorityGesture(eraseGesture(for: element), including: eraseMask(for: element))
                    // Holding a function plot opens the big settings sheet
                    // directly — no detour through the system context menu,
                    // which is a second gesture recognizer listening for the
                    // same hold and reads, from the user's side, as "holding
                    // doesn't do anything" when the menu's own preview
                    // animation is mistaken for nothing happening.
                    .highPriorityGesture(functionPlotHoldGesture(for: element), including: functionPlotHoldMask(for: element))
                    // Press and hold: the thing you pressed lifts off the page,
                    // the page behind it blurs, and the actions drop out
                    // underneath it. That's the system context menu — a popover
                    // with a pointer was the wrong shape for "act on this".
                    .contextMenu { actionMenu(for: element) }
                    // Fires once the awaited `model.updateElement` from a drag
                    // or resize actually lands and this element's own geometry
                    // changes to match — the right moment to drop the local
                    // live-drag preview. Resetting `dragOffset`/`resizeDelta`
                    // synchronously in the gesture's `onEnded`, before that
                    // update landed, is what made a resize shrink back to its
                    // OLD size for a frame and then jump to the new one: this
                    // element's `width`/`height` here were still the pre-resize
                    // values (the array hadn't refreshed yet) at the exact
                    // moment the live delta got zeroed.
                    .onChange(of: element.frame) { _, _ in
                        if draggingID == element.id { draggingID = nil; dragOffset = .zero }
                        if resizingID == element.id { resizingID = nil; resizeDelta = .zero }
                    }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .quickLookPreview($previewURL)
        .sheet(item: editingFunctionPlotBinding) { element in
            FunctionPlotSettingsSheet(
                isNew: false,
                toolState: toolState,
                mode: element.resolvedPlotMode,
                expression: element.functionExpression ?? "",
                secondary: element.functionSecondaryExpression,
                tertiary: element.functionTertiaryExpression,
                window: element.functionWindow ?? toolState.functionPlotWindow,
                axisXLabel: element.axisXLabel, axisYLabel: element.axisYLabel, axisZLabel: element.axisZLabel,
                axisXUnit: element.axisXUnit, axisYUnit: element.axisYUnit, axisZUnit: element.axisZUnit,
                axisXDisplay: element.axisXDisplay, axisYDisplay: element.axisYDisplay, axisZDisplay: element.axisZDisplay,
                lineColorHex: element.textColorHex ?? FunctionPlotSettings.defaultLineHex,
                backgroundColorHex: element.colorHex ?? FunctionPlotSettings.defaultBackgroundHex,
                transparentBackground: element.backgroundIsTransparent ?? toolState.functionPlotTransparentBackground,
                cornerRadius: element.codeCornerRadius ?? toolState.functionPlotCornerRadius,
                onCommit: { draft, lineHex, backgroundHex, cornerRadius, transparent in
                    var updated = element
                    updated.functionExpression = draft.expression
                    updated.functionSecondaryExpression = draft.secondary
                    updated.functionTertiaryExpression = draft.tertiary
                    updated.functionMode = draft.mode.rawValue
                    updated.functionWindow = draft.window
                    updated.axisXLabel = draft.axisXLabel
                    updated.axisYLabel = draft.axisYLabel
                    updated.axisZLabel = draft.axisZLabel
                    updated.axisXUnit = draft.axisXUnit
                    updated.axisYUnit = draft.axisYUnit
                    updated.axisZUnit = draft.axisZUnit
                    updated.axisXTickFormat = draft.axisXTickFormat?.rawValue
                    updated.axisYTickFormat = draft.axisYTickFormat?.rawValue
                    updated.axisZTickFormat = draft.axisZTickFormat?.rawValue
                    updated.axisXTickInterval = draft.axisXTickInterval
                    updated.axisYTickInterval = draft.axisYTickInterval
                    updated.axisZTickInterval = draft.axisZTickInterval
                    updated.textColorHex = lineHex
                    updated.colorHex = backgroundHex
                    updated.codeCornerRadius = cornerRadius
                    updated.backgroundIsTransparent = transparent
                    registerElementStep(before: element, after: updated, named: "Edit graph")
                    Task { await model.updateElement(updated, on: pageID) }
                    editingFunctionPlotID = nil
                },
                onDelete: {
                    registerElementStep(before: element, after: nil, named: "Delete graph")
                    Task { await model.deleteElement(element.id, on: pageID) }
                    editingFunctionPlotID = nil
                }
            )
        }
    }

    /// `.sheet(item:)` needs an `Identifiable` binding — looks the id back up
    /// against the live `elements` array each time, so the sheet always shows
    /// the CURRENT element (not a stale copy from when the hold happened).
    private var editingFunctionPlotBinding: Binding<PageElement?> {
        Binding(
            get: { editingFunctionPlotID.flatMap { id in elements.first { $0.id == id } } },
            set: { if $0 == nil { editingFunctionPlotID = nil } }
        )
    }

    private func functionPlotHoldMask(for element: PageElement) -> GestureMask {
        allowsEditing && element.kind == .functionPlot ? .all : .subviews
    }

    private func functionPlotHoldGesture(for element: PageElement) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .onEnded { _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                editingFunctionPlotID = element.id
            }
    }

    /// The element's size for a given resize translation (view-space points).
    /// Logical points, top-left anchored — the handle only ever grows/shrinks
    /// toward the bottom-right corner, same as pinch-resize.
    private func resizedSize(
        for element: PageElement, translation: CGSize
    ) -> (width: Double, height: Double) {
        let maxWidth = logicalSize.width - element.x
        let maxHeight = logicalSize.height - element.y
        let width = min(maxWidth, max(Self.minimumElementSide, element.width + translation.width / scale))
        let height = min(maxHeight, max(Self.minimumElementSide, element.height + translation.height / scale))
        return (width, height)
    }

    /// The element's size, live-adjusted while the corner handle is being
    /// dragged; unchanged otherwise.
    private func resizedSize(for element: PageElement) -> (width: Double, height: Double) {
        guard resizingID == element.id else { return (element.width, element.height) }
        return resizedSize(for: element, translation: resizeDelta)
    }

    /// A small, precise grab point at the element's bottom-right corner. The
    /// dot is drawn small so it doesn't dominate a small element, but its hit
    /// target is a generous 32pt box centered on it.
    private func resizeHandle(for element: PageElement) -> some View {
        Circle()
            .fill(theme.accent.color)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        resizingID = element.id
                        resizeDelta = value.translation
                    }
                    .onEnded { value in
                        var updated = element
                        (updated.width, updated.height) = resizedSize(for: element, translation: value.translation)
                        // `resizingID`/`resizeDelta` are left alone here — see
                        // the `.onChange(of: element.frame)` on the element's
                        // own view, which drops them once this update lands.
                        // A drag that landed back at the floor size it started
                        // at produces no frame change, so reset right away —
                        // same reasoning as the drag handler above.
                        if updated.frame == element.frame {
                            resizingID = nil
                            resizeDelta = .zero
                        }
                        registerElementStep(before: element, after: updated, named: "Resize")
                        Task { await model.updateElement(updated, on: pageID) }
                    }
            )
    }

    /// Registers one undo step for a single element's before/after state — the
    /// common case for drag, resize, tape toggle. `after == nil` means the
    /// element was deleted.
    private func registerElementStep(before: PageElement, after: PageElement?, named: String) {
        let previous = elements
        let updated: [PageElement]
        if let after {
            updated = previous.map { $0.id == before.id ? after : $0 }
        } else {
            updated = previous.filter { $0.id != before.id }
        }
        tracker?.registerElementStep(pageID: pageID, elementsBefore: previous, elementsAfter: updated, named: named)
    }

    /// Tape must stay tappable even while the pencil is drawing (that's the point
    /// of it), but nothing should be draggable mid-stroke.
    private func gestureMask(for element: PageElement) -> GestureMask {
        allowsEditing ? .all : .subviews
    }

    /// The eraser takes tape, typeset text and pasted images off the page.
    /// It's live only for those kinds, and only while the eraser is the
    /// selected tool — anywhere else this gesture must not exist, or it would
    /// swallow the taps that lift a strip, the drags that move a photo, and
    /// the taps that edit a text box. Ink under either is untouched: the
    /// canvas below still gets every touch that isn't on one of them.
    ///
    /// Text is included alongside tape because a beautified (or hand-placed)
    /// run is a `PageElement`, not `PKDrawing` ink — PencilKit's own eraser,
    /// pixel or vector, can only ever touch raw strokes, so without this a
    /// typeset line could never be erased at all. A code block is the same
    /// kind of typeset content. `.image` is here for the same reason a lasso
    /// Paste lands as one: it's a `PageElement`, not ink, so scrubbing the
    /// eraser across a pasted snip used to do nothing at all — the only way
    /// to remove it was the context menu's Delete.
    private func eraseMask(for element: PageElement) -> GestureMask {
        toolState.tool == .eraser && Self.erasableKinds.contains(element.kind)
            ? .all : .subviews
    }

    private static let erasableKinds: Set<PageElement.Kind> = [.tape, .text, .codeBlock, .functionPlot, .image]

    /// Touch down anywhere on a strip or a text box removes it — so scrubbing
    /// the eraser across a page takes out every one it passes over, which is
    /// what an eraser should do.
    private func eraseGesture(for element: PageElement) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard toolState.tool == .eraser, Self.erasableKinds.contains(element.kind)
                else { return }
                guard erasedElementIDs.insert(element.id).inserted else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                registerElementStep(before: element, after: nil, named: "Erase")
                Task { await model.deleteElement(element.id, on: pageID) }
            }
    }

    // MARK: - Interactions

    private func handleTap(_ element: PageElement) {
        // Tapping picks the element out — this is what makes its resize
        // handle appear. Tape excluded: it never wears one (see the `ZStack`
        // above), and its own tap already means something else entirely.
        if element.kind != .tape {
            selectedElementID.wrappedValue = element.id
        }
        switch element.kind {
        case .tape:
            // Lift the strip to reveal what's underneath, or put it back.
            var toggled = element
            toggled.isHidden.toggle()
            registerElementStep(before: element, after: toggled, named: "Tape")
            Task { await model.toggleTape(element.id, on: pageID) }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .file:
            guard let filename = element.payloadFilename else { return }
            previewURL = model.mediaURL(filename: filename)
        case .link:
            guard let string = element.urlString, let url = URL(string: string) else { return }
            openURL(url)
        case .text, .codeBlock:
            guard allowsEditing else { return }
            editingTextID = element.id
            textFieldFocused = true
        case .functionPlot:
            // A tap works too, not only the hold — the settings sheet is the
            // same either way.
            guard allowsEditing else { return }
            editingFunctionPlotID = element.id
        case .image, .audio, .fill, .unknown:
            break
        }
    }

    @ViewBuilder
    private func actionMenu(for element: PageElement) -> some View {
        if element.kind == .file, element.payloadFilename != nil {
            Button {
                if let filename = element.payloadFilename {
                    previewURL = model.mediaURL(filename: filename)
                }
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
        }
        if element.kind == .link, let string = element.urlString, let url = URL(string: string) {
            Button { openURL(url) } label: { Label("Open link", systemImage: "safari") }
        }
        if element.kind == .text {
            Button {
                editingTextID = element.id
                textFieldFocused = true
            } label: {
                Label("Edit text", systemImage: "pencil")
            }
        }
        if element.kind == .codeBlock {
            Button {
                editingTextID = element.id
                textFieldFocused = true
            } label: {
                Label("Edit code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        // Function plots skip this menu entirely: `functionPlotHoldGesture`
        // opens the settings sheet directly on the SAME hold gesture the
        // context menu would otherwise also be listening for, and having
        // both meant holding could just as easily surface a menu with an
        // "Edit function" row still one more tap away, which is exactly the
        // "holding doesn't do anything" feeling this was meant to fix.
        if element.kind == .tape {
            Button {
                Task { await model.toggleTape(element.id, on: pageID) }
            } label: {
                Label(
                    element.isHidden ? "Cover again" : "Reveal",
                    systemImage: element.isHidden ? "eye.slash" : "eye"
                )
            }
        }
        Button(role: .destructive) {
            registerElementStep(before: element, after: nil, named: "Delete")
            Task { await model.deleteElement(element.id, on: pageID) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Decoded once per file, not once per frame: `elementView` re-runs on
    /// every live-resize/drag tick, and reading + decoding the same photo off
    /// disk that often is what made resizing an image look like it blinked.
    private func cachedImage(filename: String) -> UIImage? {
        let url = model.mediaURL(filename: filename)
        let key = url.path
        if let cached = PageImageCache.shared.image(for: key) { return cached }
        guard let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) else {
            return nil
        }
        PageImageCache.shared.set(uiImage, for: key)
        return uiImage
    }

    @ViewBuilder
    private func elementView(_ element: PageElement) -> some View {
        switch element.kind {
        case .fill:
            // Drawn by `PageFillLayer`, under the ink. Never reached.
            Color.clear
        case .image:
            if let filename = element.payloadFilename,
               let uiImage = cachedImage(filename: filename) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.separator.color, lineWidth: 0.5)
                    )
            } else {
                placeholder(symbol: "photo")
            }
        case .file:
            chip(element, systemImage: "doc.fill", title: element.displayName ?? "File")
        case .link:
            chip(
                element, systemImage: "link",
                title: element.displayName ?? element.urlString ?? "Link"
            )
        case .audio:
            if let filename = element.payloadFilename {
                VoiceBubbleView(
                    url: model.mediaURL(filename: filename),
                    duration: element.durationSeconds ?? 0,
                    seed: element.id.hashValue
                )
            } else {
                placeholder(symbol: "waveform")
            }
        case .text:
            textElement(element)
        case .codeBlock:
            codeBlockElement(element)
        case .functionPlot:
            functionPlotElement(element)
        case .unknown:
            // A kind this build doesn't recognise. Nothing to draw — the
            // point of decoding to `.unknown` rather than throwing is that
            // the page's OTHER elements still load; this one just sits out.
            Color.clear
        case .tape:
            TapeView(
                shape: element.tapeShape ?? .rectangle,
                pattern: element.tapePattern ?? .solid,
                color: element.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accentMuted,
                points: element.points.map {
                    CGPoint(x: $0.x * scale, y: $0.y * scale)
                },
                thickness: (element.strokeWidth ?? TapeGeometry.defaultThickness) * scale,
                isLifted: element.isHidden
            )
        }
    }

    // MARK: - Text boxes

    @ViewBuilder
    private func textElement(_ element: PageElement) -> some View {
        if editingTextID == element.id {
            TextBoxEditor(
                element: element,
                scale: scale,
                font: textFont(element),
                onCommit: { text in
                    var updated = element
                    updated.text = text
                    // Grow the box to fit what was typed so nothing is clipped.
                    updated.height = max(
                        element.height,
                        Double(text.split(separator: "\n").count) * element.resolvedFontSize * 1.5 + 16
                    )
                    Task {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            await model.deleteElement(element.id, on: pageID)
                        } else {
                            await model.updateElement(updated, on: pageID)
                        }
                    }
                    editingTextID = nil
                }
            )
            .focused($textFieldFocused)
        } else {
            Text(element.text ?? "")
                .font(textFont(element))
                .lineSpacing(element.extraLeading * scale)
                .foregroundStyle((element.textColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink).color)
                .padding(6 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func textFont(_ element: PageElement) -> Font {
        FontResolver.font(
            named: element.fontName,
            size: element.resolvedFontSize * scale,
            bold: element.isBold
        )
    }

    // MARK: - Code blocks

    @ViewBuilder
    private func codeBlockElement(_ element: PageElement) -> some View {
        let radius = (element.codeCornerRadius ?? toolState.codeBlockCornerRadius) * scale
        let background = ThemeColor(hex: element.colorHex ?? CodeBlockSettings.defaultBackgroundHex)
            ?? theme.surfaceRaised
        let foreground = ThemeColor(hex: element.textColorHex ?? CodeBlockSettings.defaultTextHex)
            ?? theme.ink
        let transparent = element.backgroundIsTransparent ?? toolState.codeBlockTransparentBackground

        Group {
            if editingTextID == element.id {
                CodeBlockEditor(
                    element: element, scale: scale, font: textFont(element), foreground: foreground.color,
                    onCommit: { text in
                        var updated = element
                        updated.text = text
                        updated.height = max(
                            element.height,
                            Double(text.split(separator: "\n").count) * element.resolvedFontSize * 1.4 + 24
                        )
                        Task {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                await model.deleteElement(element.id, on: pageID)
                            } else {
                                await model.updateElement(updated, on: pageID)
                            }
                        }
                        editingTextID = nil
                    }
                )
                .focused($textFieldFocused)
            } else {
                Text(CodeBlockText.attributed(
                    element.text?.isEmpty == false ? element.text! : " ",
                    language: CodeLanguage(rawValue: element.codeLanguage ?? "") ?? .plaintext,
                    plainColor: foreground, background: background
                ))
                .font(textFont(element))
                .lineSpacing(element.extraLeading * scale)
                .padding(10 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(transparent ? Color.clear : background.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if !transparent {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.separator.color, lineWidth: 0.5)
            }
        }
    }

    // MARK: - Function plots

    /// Editing a function plot ALWAYS goes through the big
    /// `FunctionPlotSettingsSheet` now — never the compact inline editor a
    /// tap used to open directly at the block's own (often tiny) on-page
    /// size, which is exactly what made it feel too cramped to use.
    @ViewBuilder
    private func functionPlotElement(_ element: PageElement) -> some View {
        let radius = (element.codeCornerRadius ?? toolState.functionPlotCornerRadius) * scale
        let background = ThemeColor(hex: element.colorHex ?? FunctionPlotSettings.defaultBackgroundHex)
            ?? theme.surfaceRaised
        let lineColor = ThemeColor(hex: element.textColorHex ?? FunctionPlotSettings.defaultLineHex)
            ?? theme.accent
        let transparent = element.backgroundIsTransparent ?? toolState.functionPlotTransparentBackground

        FunctionPlotView(
            expression: element.functionExpression ?? "",
            secondaryExpression: element.functionSecondaryExpression,
            tertiaryExpression: element.functionTertiaryExpression,
            mode: element.resolvedPlotMode,
            window: element.functionWindow ?? toolState.functionPlotWindow,
            lineColor: lineColor.color, axisColor: lineColor.color,
            axisX: element.axisXDisplay, axisY: element.axisYDisplay, axisZ: element.axisZDisplay
        )
        .padding(6 * scale)
        .background(transparent ? Color.clear : background.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if !transparent {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.separator.color, lineWidth: 0.5)
            }
        }
    }

    // MARK: - Chrome

    private func chip(_ element: PageElement, systemImage: String, title: String) -> some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.accent.color)
            Text(title)
                .font(.dsSystem(size: 15 * scale, weight: .medium))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 12 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
    }

    private func placeholder(symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.surfaceRaised.color)
            .overlay(Image(systemName: symbol).foregroundStyle(theme.inkSecondary.color))
    }

    private func dragGesture(for element: PageElement) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                draggingID = element.id
                dragOffset = value.translation
            }
            .onEnded { value in
                var updated = element
                updated.x = max(0, min(logicalSize.width - element.width,
                                       element.x + value.translation.width / scale))
                updated.y = max(0, min(logicalSize.height - element.height,
                                       element.y + value.translation.height / scale))
                // `draggingID`/`dragOffset` are left alone here — see the
                // `.onChange(of: element.frame)` on the element's own view,
                // which drops them once this update actually lands. A drag
                // that got clamped straight back to where it started (a shove
                // against the page edge) produces no frame change at all, so
                // nothing would ever fire that `onChange` — reset right away
                // in that case, since there's no update in flight to wait for.
                if updated.frame == element.frame {
                    draggingID = nil
                    dragOffset = .zero
                }
                registerElementStep(before: element, after: updated, named: "Move")
                Task { await model.updateElement(updated, on: pageID) }
            }
    }

    /// Pinch to resize (keeps the top-left corner anchored). Best used in the
    /// rail's Move mode, where the pencil doesn't draw.
    private func resizeGesture(for element: PageElement) -> some Gesture {
        MagnifyGesture()
            .onEnded { value in
                let factor = max(0.3, min(3, value.magnification))
                var updated = element
                let newW = min(logicalSize.width, max(40, element.width * factor))
                let newH = min(logicalSize.height, max(40, element.height * factor))
                updated.width = newW
                updated.height = newH
                updated.x = min(updated.x, logicalSize.width - newW)
                updated.y = min(updated.y, logicalSize.height - newH)
                registerElementStep(before: element, after: updated, named: "Resize")
                Task { await model.updateElement(updated, on: pageID) }
            }
    }
}

/// An invisible, eraser-only hit layer for elements that render BELOW the ink
/// canvas (`.text`, `.codeBlock` — see `PageElementsLayer`'s `belowInk` pass).
/// Ink is deliberately drawn ABOVE those elements so a stroke over one shows on
/// top of it, but that also makes `PageCanvasView` the hit-test winner for the
/// WHOLE page the instant the eraser tool is selected
/// (`PageCanvasView.interceptsTouches`) — so the erase gesture already wired to
/// those elements (`PageElementsLayer.eraseGesture`) can never actually be
/// reached by a touch; it's correctly wired but structurally unreachable. This
/// sits ABOVE the canvas instead (next to the tape layer, which needs the same
/// "erase has to win" ordering) and is the only place that can receive the
/// touch, without changing the visual z-order that ink-over-text depends on.
struct EraseCatcherLayer: View {
    let pageID: UUID
    let elements: [PageElement]
    let model: NotebookEditorModel
    let toolState: ToolState
    let displaySize: CGSize
    let logicalSize: CGSize
    var tracker: ActiveCanvasTracker?

    @State private var erasedElementIDs: Set<UUID> = []

    private var scale: CGFloat { displaySize.width / max(logicalSize.width, 1) }

    static let catchableKinds: Set<PageElement.Kind> = [.text, .codeBlock, .functionPlot]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(elements.filter { Self.catchableKinds.contains($0.kind) }) { element in
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: element.width * scale, height: element.height * scale)
                    .rotationEffect(.degrees(element.rotation))
                    .position(
                        x: (element.x + element.width / 2) * scale,
                        y: (element.y + element.height / 2) * scale
                    )
                    .gesture(eraseGesture(for: element))
            }
            // Fills paint UNDER the ink (`PageFillLayer`) and are never part of
            // either `PageElementsLayer` instance — so, like text/code/plots
            // above, the eraser can only ever reach one by catching it up here,
            // ABOVE the ink. Unlike those, a fill isn't a box: its outline is an
            // arbitrary flood-fill polygon, so the hit area traces that same
            // outline (scaled exactly as `PageFillLayer` draws it) instead of a
            // rectangle — erasing only where the paint actually is, not the
            // shape's whole bounding box.
            ForEach(elements.filter { $0.kind == .fill }) { element in
                Color.clear
                    .contentShape(fillOutline(element))
                    .frame(width: displaySize.width, height: displaySize.height)
                    // `.highPriorityGesture`, not `.gesture` — this drag has to
                    // WIN outright the instant it starts, not merely compete.
                    // SwiftUI's gesture system defaults to one winner per touch
                    // sequence, and this view sits stacked among several other
                    // full-page catcher layers here (plus the canvas itself,
                    // still hit-testable during eraser mode). A plain `.gesture`
                    // left this drag able to be silently pre-empted the instant
                    // ANYTHING else nearby began recognizing — which reads as
                    // exactly what was reported: erasing behaves like a single
                    // tap (only the touch-down sample ever gets through) rather
                    // than a continuous sweep, and which fill actually takes
                    // the bite looks arbitrary because it's whichever recognizer
                    // happened to win the race that particular time.
                    .highPriorityGesture(fillEraseGesture(for: element))
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .allowsHitTesting(toolState.tool == .eraser)
    }

    private func fillOutline(_ element: PageElement) -> Path {
        var path = Path()
        let scaled = element.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        guard let first = scaled.first else { return path }
        path.move(to: first)
        for point in scaled.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private func eraseGesture(for element: PageElement) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard erasedElementIDs.insert(element.id).inserted else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let before = elements
                let after = before.filter { $0.id != element.id }
                tracker?.registerElementStep(
                    pageID: pageID, elementsBefore: before, elementsAfter: after, named: "Erase"
                )
                Task { await model.deleteElement(element.id, on: pageID) }
            }
    }

    /// A fill has real erasable area (unlike text/code/plots, which are
    /// delete-on-touch), so a drag across it only takes out where the eraser
    /// actually swept, in `FillGeometry.erased`'s working page space — not the
    /// whole element the first time the touch lands inside it. The swept points
    /// accumulate for the length of the drag; the mask is only rasterized and
    /// re-traced once, on release, since a rasterize-flood-trace pass per touch
    /// sample would be the exact per-frame cost that made function-plot resize
    /// stutter, paid on every eraser stroke instead of only every resize.
    @State private var erasePath: [UUID: [CGPoint]] = [:]

    private func fillEraseGesture(for element: PageElement) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                if erasePath[element.id] == nil {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                erasePath[element.id, default: []].append(point)
            }
            .onEnded { _ in
                defer { erasePath[element.id] = nil }
                guard let swept = erasePath[element.id], !swept.isEmpty else { return }
                let before = elements
                let survivingOutline = FillGeometry.erased(
                    outline: element.points.map(\.cgPoint),
                    erasedPoints: swept,
                    radius: CGFloat(max(toolState.eraserWidth / 2, 6)),
                    scale: FillTool.maskScale
                )
                if let survivingOutline {
                    var updated = element
                    updated.points = survivingOutline.map(PagePoint.init)
                    tracker?.registerElementStep(
                        pageID: pageID, elementsBefore: before,
                        elementsAfter: before.map { $0.id == element.id ? updated : $0 }, named: "Erase"
                    )
                    Task { await model.updateElement(updated, on: pageID) }
                } else {
                    let after = before.filter { $0.id != element.id }
                    tracker?.registerElementStep(
                        pageID: pageID, elementsBefore: before, elementsAfter: after, named: "Erase"
                    )
                    Task { await model.deleteElement(element.id, on: pageID) }
                }
            }
    }
}

/// The in-place editor for a text box: a real keyboard field sitting exactly where
/// the box is, so typing on the page feels like typing on paper.
private struct TextBoxEditor: View {
    @Environment(\.theme) private var theme

    let element: PageElement
    let scale: CGFloat
    let font: Font
    let onCommit: (String) -> Void

    @State private var draft: String

    init(element: PageElement, scale: CGFloat, font: Font, onCommit: @escaping (String) -> Void) {
        self.element = element
        self.scale = scale
        self.font = font
        self.onCommit = onCommit
        _draft = State(initialValue: element.text ?? "")
    }

    var body: some View {
        TextField("Type…", text: $draft, axis: .vertical)
            .font(font)
            .foregroundStyle((element.textColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink).color)
            .textFieldStyle(.plain)
            .padding(6 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.accentMuted.withAlpha(0.35).color,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.accent.color, lineWidth: 1.5)
            )
            .onSubmit { onCommit(draft) }
            .onDisappear { onCommit(draft) }
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Button("Done") { onCommit(draft) }
                        .font(.dsSubheadline.weight(.semibold))
                }
            }
    }
}

/// The in-place editor for a code block: a multiline field with autocorrect
/// and autocapitalization off, so typing code doesn't fight the keyboard.
/// Undecorated — `codeBlockElement` already draws the background, corner
/// radius and border this sits inside, whether editing or not.
private struct CodeBlockEditor: View {
    let element: PageElement
    let scale: CGFloat
    let font: Font
    let foreground: Color
    let onCommit: (String) -> Void

    @State private var draft: String

    init(
        element: PageElement, scale: CGFloat, font: Font, foreground: Color,
        onCommit: @escaping (String) -> Void
    ) {
        self.element = element
        self.scale = scale
        self.font = font
        self.foreground = foreground
        self.onCommit = onCommit
        _draft = State(initialValue: element.text ?? "")
    }

    var body: some View {
        TextEditor(text: $draft)
            .font(font)
            .foregroundStyle(foreground)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .padding(4 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onDisappear { onCommit(draft) }
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Button("Done") { onCommit(draft) }
                        .font(.dsSubheadline.weight(.semibold))
                }
            }
    }
}
