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
    /// Which elements this instance renders, relative to the ink layer.
    var layer: Layer = .all

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
        case .belowInk: return nonFill.filter { $0.kind != .tape }
        case .aboveInk: return nonFill.filter { $0.kind == .tape }
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
                        if allowsEditing, element.kind != .tape {
                            resizeHandle(for: element)
                        }
                    }
                    .rotationEffect(.degrees(element.rotation))
                    .position(
                        x: (element.x + liveWidth / 2) * scale + live.width,
                        y: (element.y + liveHeight / 2) * scale + live.height
                    )
                    .gesture(dragGesture(for: element), including: gestureMask(for: element))
                    .simultaneousGesture(resizeGesture(for: element), including: gestureMask(for: element))
                    .onTapGesture { handleTap(element) }
                    // Erasing tape wins over lifting it, so a rubbed-out strip is
                    // gone rather than merely revealed.
                    .highPriorityGesture(eraseGesture(for: element), including: eraseMask(for: element))
                    // Press and hold: the thing you pressed lifts off the page,
                    // the page behind it blurs, and the actions drop out
                    // underneath it. That's the system context menu — a popover
                    // with a pointer was the wrong shape for "act on this".
                    .contextMenu { actionMenu(for: element) }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .quickLookPreview($previewURL)
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
                        resizingID = nil
                        resizeDelta = .zero
                        Task { await model.updateElement(updated, on: pageID) }
                    }
            )
    }

    /// Tape must stay tappable even while the pencil is drawing (that's the point
    /// of it), but nothing should be draggable mid-stroke.
    private func gestureMask(for element: PageElement) -> GestureMask {
        allowsEditing ? .all : .subviews
    }

    /// The eraser takes tape and typeset text off the page. It's live only for
    /// those two kinds, and only while the eraser is the selected tool —
    /// anywhere else this gesture must not exist, or it would swallow the taps
    /// that lift a strip, the drags that move a photo, and the taps that edit a
    /// text box. Ink under either is untouched: the canvas below still gets
    /// every touch that isn't on one of them.
    ///
    /// Text is included alongside tape because a beautified (or hand-placed)
    /// run is a `PageElement`, not `PKDrawing` ink — PencilKit's own eraser,
    /// pixel or vector, can only ever touch raw strokes, so without this a
    /// typeset line could never be erased at all. A code block is the same
    /// kind of typeset content.
    private func eraseMask(for element: PageElement) -> GestureMask {
        toolState.tool == .eraser && Self.erasableKinds.contains(element.kind)
            ? .all : .subviews
    }

    private static let erasableKinds: Set<PageElement.Kind> = [.tape, .text, .codeBlock]

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
                Task { await model.deleteElement(element.id, on: pageID) }
            }
    }

    // MARK: - Interactions

    private func handleTap(_ element: PageElement) {
        switch element.kind {
        case .tape:
            // Lift the strip to reveal what's underneath, or put it back.
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
            Task { await model.deleteElement(element.id, on: pageID) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func elementView(_ element: PageElement) -> some View {
        switch element.kind {
        case .fill:
            // Drawn by `PageFillLayer`, under the ink. Never reached.
            Color.clear
        case .image:
            if let filename = element.payloadFilename,
               let data = try? Data(contentsOf: model.mediaURL(filename: filename)),
               let uiImage = UIImage(data: data) {
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
                Text(element.text?.isEmpty == false ? element.text! : " ")
                    .font(textFont(element))
                    .lineSpacing(element.extraLeading * scale)
                    .foregroundStyle(foreground.color)
                    .padding(10 * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(background.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
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
                draggingID = nil
                dragOffset = .zero
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
                Task { await model.updateElement(updated, on: pageID) }
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
