import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI
import UIKit

/// Renders and edits the media / voice / text elements layered over one page's
/// ink. Elements are stored in logical page space and scaled to the displayed
/// page size. Drag to move; long-press for delete.
struct PageElementsLayer: View {
    @Environment(\.theme) private var theme

    let pageID: UUID
    let elements: [PageElement]
    let model: NotebookEditorModel
    /// Displayed page size in view points (from the parent GeometryReader).
    let displaySize: CGSize

    private var scale: CGFloat { displaySize.width / PageGeometry.size.width }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(elements) { element in
                elementView(element)
                    .frame(width: element.width * scale, height: element.height * scale)
                    .rotationEffect(.degrees(element.rotation))
                    .position(
                        x: (element.x + element.width / 2) * scale,
                        y: (element.y + element.height / 2) * scale
                    )
                    .gesture(dragGesture(for: element))
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await model.deleteElement(element.id, on: pageID) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
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
        DragGesture()
            .onEnded { value in
                var updated = element
                updated.x = max(0, min(PageGeometry.size.width - element.width, element.x + value.translation.width / scale))
                updated.y = max(0, min(PageGeometry.size.height - element.height, element.y + value.translation.height / scale))
                Task { await model.updateElement(updated, on: pageID) }
            }
    }
}
