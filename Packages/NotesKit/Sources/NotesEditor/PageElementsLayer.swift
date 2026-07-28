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

    /// Live drag translation for the element currently under the finger, so the
    /// bubble tracks the finger instead of jumping on release.
    @State private var dragOffset: CGSize = .zero
    @State private var draggingID: UUID?
    /// Strips already removed by the eraser gesture in flight, so one continuous
    /// scrub deletes each one exactly once.
    @State private var erasedElementIDs: Set<UUID> = []
    @State private var previewURL: URL?
    @FocusState private var textFieldFocused: Bool

    private var scale: CGFloat { displaySize.width / max(logicalSize.width, 1) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(elements) { element in
                let live = draggingID == element.id ? dragOffset : .zero
                elementView(element)
                    .frame(width: element.width * scale, height: element.height * scale)
                    .rotationEffect(.degrees(element.rotation))
                    .position(
                        x: (element.x + element.width / 2) * scale + live.width,
                        y: (element.y + element.height / 2) * scale + live.height
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

    /// Tape must stay tappable even while the pencil is drawing (that's the point
    /// of it), but nothing should be draggable mid-stroke.
    private func gestureMask(for element: PageElement) -> GestureMask {
        allowsEditing ? .all : .subviews
    }

    /// The eraser takes tape off the page. It's live only for tape, and only while
    /// the eraser is the selected tool — anywhere else this gesture must not exist,
    /// or it would swallow the taps that lift a strip and the drags that move a
    /// photo. Ink under the strip is untouched: the canvas below still gets every
    /// touch that isn't on a strip.
    private func eraseMask(for element: PageElement) -> GestureMask {
        toolState.tool == .eraser && element.kind == .tape ? .all : .subviews
    }

    /// Touch down anywhere on a strip removes it — so scrubbing the eraser across a
    /// page takes out every strip it passes over, which is what an eraser should do.
    private func eraseGesture(for element: PageElement) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard toolState.tool == .eraser, element.kind == .tape else { return }
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
        case .text:
            guard allowsEditing else { return }
            editingTextID = element.id
            textFieldFocused = true
        case .image, .audio:
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
                .foregroundStyle((element.textColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink).color)
                .padding(6 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func textFont(_ element: PageElement) -> Font {
        let size = element.resolvedFontSize * scale
        guard let name = element.fontName, name != "system" else {
            return .system(size: size, weight: element.isBold ? .bold : .regular)
        }
        let base = Font.custom(name, size: size)
        return element.isBold ? base.weight(.bold) : base
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
