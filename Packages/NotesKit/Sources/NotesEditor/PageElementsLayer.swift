import ClassMateTheme
import NotesDesignSystem
import NotesModels
import QuickLook
import SwiftUI
import UIKit

/// Renders and edits the media / voice / text elements layered over one page's
/// ink. Elements are stored in logical page space and scaled to the displayed
/// page size. Drag to move (live, 1:1); long-press for a small action menu;
/// tap a file to open it.
struct PageElementsLayer: View {
    @Environment(\.theme) private var theme

    let pageID: UUID
    let elements: [PageElement]
    let model: NotebookEditorModel
    /// Displayed page size in view points (from the parent GeometryReader).
    let displaySize: CGSize

    /// Live drag translation for the element currently under the finger, so the
    /// bubble tracks the finger instead of jumping on release.
    @State private var dragOffset: CGSize = .zero
    @State private var draggingID: UUID?
    @State private var menuElementID: UUID?
    @State private var previewURL: URL?

    private var scale: CGFloat { displaySize.width / PageGeometry.size.width }

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
                    .gesture(dragGesture(for: element))
                    .simultaneousGesture(resizeGesture(for: element))
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

    private func menuBinding(for element: PageElement) -> Binding<Bool> {
        Binding(
            get: { menuElementID == element.id },
            set: { if !$0 { menuElementID = nil } }
        )
    }

    // MARK: - Interactions

    private func handleTap(_ element: PageElement) {
        // Tapping a file opens it in QuickLook (renders PDFs, docs, etc.).
        guard element.kind == .file, let filename = element.payloadFilename else { return }
        previewURL = model.mediaURL(filename: filename)
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
            fileChip(element)
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
            Text(element.text ?? "")
                .font(textFont(element))
                .foregroundStyle((element.textColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink).color)
                .padding(8 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func textFont(_ element: PageElement) -> Font {
        let size = 20 * scale
        if let name = element.fontName, name != "system" {
            return .custom(name, size: size)
        }
        return .system(size: size)
    }

    private func fileChip(_ element: PageElement) -> some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "doc.fill")
                .foregroundStyle(theme.accent.color)
            Text(element.displayName ?? "File")
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
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                draggingID = element.id
                dragOffset = value.translation
            }
            .onEnded { value in
                var updated = element
                updated.x = max(0, min(PageGeometry.size.width - element.width, element.x + value.translation.width / scale))
                updated.y = max(0, min(PageGeometry.size.height - element.height, element.y + value.translation.height / scale))
                draggingID = nil
                dragOffset = .zero
                Task { await model.updateElement(updated, on: pageID) }
            }
    }

    /// Pinch to resize (keeps the top-left corner anchored). Best used in the
    /// rail's Hand mode, where the pencil doesn't draw.
    private func resizeGesture(for element: PageElement) -> some Gesture {
        MagnifyGesture()
            .onEnded { value in
                let factor = max(0.3, min(3, value.magnification))
                var updated = element
                let newW = min(PageGeometry.size.width, max(40, element.width * factor))
                let newH = min(PageGeometry.size.height, max(40, element.height * factor))
                updated.width = newW
                updated.height = newH
                updated.x = min(updated.x, PageGeometry.size.width - newW)
                updated.y = min(updated.y, PageGeometry.size.height - newH)
                Task { await model.updateElement(updated, on: pageID) }
            }
    }
}
