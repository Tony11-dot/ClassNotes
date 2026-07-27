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
/// size. Drag to move (live, 1:1); pinch to resize; long-press for a small action
/// menu; tap a file or link to open it; tap a strip of tape to lift it; tap a text
/// box in text/move mode to type in it.
struct PageElementsLayer: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    let pageID: UUID
    let elements: [PageElement]
    let model: NotebookEditorModel
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
    @State private var menuElementID: UUID?
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
                    .simultaneousGesture(longPressGesture(for: element))
                    .onTapGesture { handleTap(element) }
                    .popover(isPresented: menuBinding(for: element)) {
                        actionMenu(for: element)
                    }
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

    private func menuBinding(for element: PageElement) -> Binding<Bool> {
        Binding(
            get: { menuElementID == element.id },
            set: { if !$0 { menuElementID = nil } }
        )
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

    private func longPressGesture(for element: PageElement) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .onEnded { _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                menuElementID = element.id
            }
    }

    @ViewBuilder
    private func actionMenu(for element: PageElement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if element.kind == .file, element.payloadFilename != nil {
                menuButton("Open", systemImage: "arrow.up.forward.app") {
                    if let filename = element.payloadFilename {
                        previewURL = model.mediaURL(filename: filename)
                    }
                    menuElementID = nil
                }
                Divider()
            }
            if element.kind == .link, let string = element.urlString, let url = URL(string: string) {
                menuButton("Open link", systemImage: "safari") {
                    openURL(url)
                    menuElementID = nil
                }
                Divider()
            }
            if element.kind == .text {
                menuButton("Edit text", systemImage: "pencil") {
                    editingTextID = element.id
                    textFieldFocused = true
                    menuElementID = nil
                }
                Divider()
            }
            if element.kind == .tape {
                menuButton(
                    element.isHidden ? "Cover again" : "Reveal",
                    systemImage: element.isHidden ? "eye.slash" : "eye"
                ) {
                    Task { await model.toggleTape(element.id, on: pageID) }
                    menuElementID = nil
                }
                Divider()
            }
            menuButton("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.deleteElement(element.id, on: pageID) }
                menuElementID = nil
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 180)
        .presentationCompactAdaptation(.popover)
    }

    private func menuButton(
        _ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .tint(role == .destructive ? .red : theme.ink.color)
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
                .font(.system(size: 15 * scale, weight: .medium))
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
                        .font(.subheadline.weight(.semibold))
                }
            }
    }
}
