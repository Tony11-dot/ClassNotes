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
    /// The notebook's cover artwork, so the cover page's thumbnail looks like the
    /// cover rather than like blank paper.
    let cover: CoverPaper?
    @Binding var isVisible: Bool
    let onSelect: (UUID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 14)]

    /// Showing only the flagged pages. A notebook of eighty pages is exactly the
    /// one where finding the four that matter is the whole point.
    @State private var bookmarksOnly = false

    private var shownPages: [(index: Int, page: PageRecord)] {
        let all = Array(model.pages.enumerated()).map { (index: $0.offset, page: $0.element) }
        return bookmarksOnly ? all.filter(\.page.isBookmarked) : all
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.separator.color)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(shownPages, id: \.page.id) { entry in
                        thumbnail(
                            entry.page,
                            number: pageNumber(at: entry.index),
                            index: entry.index
                        )
                    }
                    if !bookmarksOnly { addButton }
                }
                .padding(16)
                if bookmarksOnly, shownPages.isEmpty {
                    Text("No bookmarks yet. Long-press a page to flag it.")
                        .font(.dsFootnote)
                        .foregroundStyle(theme.inkSecondary.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
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
        HStack(spacing: 10) {
            Text("Pages").font(.dsHeadline).foregroundStyle(theme.ink.color)
            Spacer()
            Text("\(model.pages.count)")
                .font(.dsSubheadline).foregroundStyle(theme.inkSecondary.color)
            Button {
                bookmarksOnly.toggle()
            } label: {
                Image(systemName: bookmarksOnly ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(bookmarksOnly ? theme.accent.color : theme.ink.color)
                    // A bare glyph in a header is a few points tall; the touch
                    // target has to be a real one or the button reads as dead.
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(bookmarksOnly ? "Show all pages" : "Show bookmarked pages only")
            Button { isVisible = false } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(theme.ink.color)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide pages")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// The cover isn't page one — it's the cover. Numbering starts after it.
    private func pageNumber(at index: Int) -> Int {
        model.pages.prefix(index + 1).filter { !$0.isCover }.count
    }

    /// A page's paper at thumbnail size: cover artwork for the cover, the printed
    /// template for everything else.
    private func paper(_ page: PageRecord) -> some View {
        PagePaperView(page: page, cover: cover)
    }

    private func thumbnail(_ page: PageRecord, number: Int, index: Int) -> some View {
        let isCurrent = model.focusedPageID == page.id
        return VStack(spacing: 6) {
            paper(page)
                .aspectRatio(PageGeometry.size.width / PageGeometry.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCurrent ? theme.accent.color : theme.separator.color,
                                      lineWidth: isCurrent ? 2.5 : 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                .overlay(alignment: .topTrailing) {
                    if page.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.dsCaption2)
                            .foregroundStyle(theme.accent.color)
                            .shadow(color: .black.opacity(0.25), radius: 2)
                            .padding(5)
                    }
                }
            Text(page.isCover ? "Cover" : "\(number)")
                .font(.dsCaption.weight(isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? theme.accent.color : theme.inkSecondary.color)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(page.id) }
        .contextMenu {
            Button { Task { await model.toggleBookmark(page.id) } } label: {
                Label(
                    page.isBookmarked ? "Remove bookmark" : "Bookmark",
                    systemImage: page.isBookmarked ? "bookmark.slash" : "bookmark"
                )
            }
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
            paper(page)
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
                .overlay(Image(systemName: "plus").font(.dsTitle3).foregroundStyle(theme.accent.color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add page")
    }
}
