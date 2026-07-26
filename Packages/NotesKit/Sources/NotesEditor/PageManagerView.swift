import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// The page manager: a dockable side panel listing every page as a numbered
/// thumbnail, current one highlighted. Tap to jump; long-press for a menu
/// (duplicate / delete); drag a thumbnail onto another to reorder. Toggled by
/// the rail's "Pages" button.
struct PageManagerView: View {
    @Environment(\.theme) private var theme

    let model: NotebookEditorModel
    @Binding var isVisible: Bool
    let onSelect: (UUID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.separator.color)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                        thumbnail(page, number: index + 1, index: index)
                    }
                    addButton
                }
                .padding(16)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(theme.surface.color)
        .overlay(alignment: .trailing) {
            Rectangle().frame(width: 0.5).foregroundStyle(theme.separator.color)
        }
        .shadow(color: .black.opacity(0.18), radius: 20, x: 6)
    }

    private var header: some View {
        HStack {
            Text("Pages").font(.headline).foregroundStyle(theme.ink.color)
            Spacer()
            Text("\(model.pages.count)")
                .font(.subheadline).foregroundStyle(theme.inkSecondary.color)
            Button { isVisible = false } label: {
                Image(systemName: "sidebar.left").foregroundStyle(theme.ink.color)
            }
            .accessibilityLabel("Hide pages")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func thumbnail(_ page: PageRecord, number: Int, index: Int) -> some View {
        let isCurrent = model.focusedPageID == page.id
        return VStack(spacing: 6) {
            PageTemplateView(template: page.template, margin: page.margin, paperColorHex: page.paperColorHex)
                .aspectRatio(PageGeometry.size.width / PageGeometry.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCurrent ? theme.accent.color : theme.separator.color,
                                      lineWidth: isCurrent ? 2.5 : 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            Text("\(number)")
                .font(.caption.weight(isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? theme.accent.color : theme.inkSecondary.color)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(page.id) }
        .contextMenu {
            Button { Task { await model.duplicatePage(page.id) } } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button { onSelect(page.id) } label: { Label("Go to page", systemImage: "arrow.right") }
            Button(role: .destructive) { Task { await model.deletePage(page.id) } } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.pages.count <= 1)
        }
        .draggable(page.id.uuidString) {
            // Drag preview.
            PageTemplateView(template: page.template, margin: page.margin, paperColorHex: page.paperColorHex)
                .aspectRatio(PageGeometry.size.width / PageGeometry.size.height, contentMode: .fit)
                .frame(width: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first,
                  let fromIndex = model.pages.firstIndex(where: { $0.id.uuidString == dragged }) else {
                return false
            }
            Task { await model.movePage(from: fromIndex, to: index) }
            return true
        }
    }

    private var addButton: some View {
        Button {
            Task {
                let source = model.pages.last?.id
                if let id = await model.insertPage(at: model.pages.count, inheriting: source) {
                    onSelect(id)
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.separator.color, style: StrokeStyle(lineWidth: 1, dash: [5]))
                .aspectRatio(PageGeometry.size.width / PageGeometry.size.height, contentMode: .fit)
                .overlay(Image(systemName: "plus").font(.title3).foregroundStyle(theme.accent.color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add page")
    }
}
