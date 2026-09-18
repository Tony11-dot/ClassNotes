import ClassMateTheme
import NotesDesignSystem
import NotesModels
import PencilKit
import SwiftUI

/// The page manager: a dockable side panel listing every page as a numbered
/// thumbnail, current one highlighted. Tap to jump; long-press for a menu
/// (duplicate / delete); drag a thumbnail onto another to reorder; Select
/// picks several out for a batch action. Toggled by the rail's "Pages" button.
struct PageManagerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

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

    /// Select mode: `nil` means off. Non-nil (even empty) means the grid is
    /// showing checkmarks instead of jumping on tap, for the batch bar below.
    @State private var selectedPageIDs: Set<UUID>?

    /// Each page's real content, rendered once when the manager opens — the
    /// thumbnail used to be `PagePaperView` alone (the blank template), which
    /// is exactly the same picture for every page of the same style. A page
    /// picker where every thumbnail looks identical isn't a picker; this is
    /// the same ink+elements composite the iPhone viewer and the PDF export
    /// already use, just rendered small.
    @State private var inkImages: [UUID: UIImage] = [:]
    @State private var backgrounds: [UUID: UIImage] = [:]

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
                    if !bookmarksOnly, selectedPageIDs == nil { addButton }
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
            if let selectedPageIDs {
                selectionBar(selectedPageIDs)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(theme.surface.color)
        .overlay(alignment: .trailing) {
            Rectangle().frame(width: 0.5).foregroundStyle(theme.separator.color)
        }
        .shadow(color: .black.opacity(0.18), radius: 20, x: 6)
        .task { await loadThumbnails() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Pages").font(.dsHeadline).foregroundStyle(theme.ink.color)
            Spacer()
            if selectedPageIDs != nil {
                Button("Done") { selectedPageIDs = nil }
                    .font(.dsSubheadline.weight(.semibold))
            } else {
                Text("\(model.pages.count)")
                    .font(.dsSubheadline).foregroundStyle(theme.inkSecondary.color)
                Button("Select") { selectedPageIDs = [] }
                    .font(.dsSubheadline)
                    .disabled(model.pages.count <= 1)
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
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Delete / bookmark / duplicate several pages at once. A `safeAreaInset`,
    /// not a bottom overlay — the library's own multi-select bar sits the same
    /// way, for the same reason: a control drawn as a floating overlay can end
    /// up under whatever else docks to the bottom edge.
    private func selectionBar(_ selected: Set<UUID>) -> some View {
        HStack(spacing: 0) {
            Button(role: .destructive) {
                let toDelete = selected
                selectedPageIDs = nil
                Task { await model.deletePages(toDelete) }
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.dsFootnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .disabled(selected.isEmpty || selected.count >= model.pages.count)
            Divider().frame(height: 20).overlay(theme.separator.color)
            Button {
                Task {
                    for id in selected { await model.toggleBookmark(id) }
                }
                selectedPageIDs = nil
            } label: {
                Label("Bookmark", systemImage: "bookmark")
                    .font(.dsFootnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .disabled(selected.isEmpty)
        }
        .foregroundStyle(theme.ink.color)
        .frame(height: 44)
        .padding(.horizontal, 8)
        .background(theme.surface.color)
        .overlay(alignment: .top) {
            Rectangle().frame(height: 0.5).foregroundStyle(theme.separator.color)
        }
    }

    /// The cover isn't page one — it's the cover. Numbering starts after it.
    private func pageNumber(at index: Int) -> Int {
        model.pages.prefix(index + 1).filter { !$0.isCover }.count
    }

    /// A page's paper at thumbnail size: cover artwork for the cover, the printed
    /// template for everything else — the base layer content renders on top of.
    private func paper(_ page: PageRecord) -> some View {
        PagePaperView(page: page, cover: cover)
    }

    /// The full composite — paper, background, ink, elements — the same stack
    /// `PageCompositeView` renders for export, at thumbnail size.
    @ViewBuilder
    private func content(_ page: PageRecord, size: CGSize) -> some View {
        paper(page)
        if let background = backgrounds[page.id] {
            Image(uiImage: background).resizable().scaledToFit()
        }
        PageContentView(
            elements: page.elements, displaySize: size, logicalSize: page.logicalSize,
            mediaURL: { model.store.mediaURL(notebook: model.notebookID, filename: $0) },
            layer: .belowInk
        )
        if let ink = inkImages[page.id] {
            Image(uiImage: ink).resizable().scaledToFit()
        }
        PageContentView(
            elements: page.elements, displaySize: size, logicalSize: page.logicalSize,
            mediaURL: { model.store.mediaURL(notebook: model.notebookID, filename: $0) },
            layer: .aboveInk
        )
    }

    private func thumbnail(_ page: PageRecord, number: Int, index: Int) -> some View {
        let isCurrent = model.focusedPageID == page.id
        let isSelected = selectedPageIDs?.contains(page.id) ?? false
        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack { content(page, size: geo.size) }
            }
            .aspectRatio(PageGeometry.size.width / PageGeometry.size.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent.color : (isCurrent ? theme.accent.color : theme.separator.color),
                        lineWidth: isSelected || isCurrent ? 2.5 : 0.5
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if selectedPageIDs != nil {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.dsBody)
                        .foregroundStyle(isSelected ? theme.accent.color : .white)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .padding(5)
                } else if page.isBookmarked {
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
        .onTapGesture {
            if selectedPageIDs != nil {
                toggleSelection(page.id)
            } else {
                onSelect(page.id)
            }
        }
        .contextMenu {
            if selectedPageIDs == nil {
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
        }
        .draggable(page.id.uuidString) {
            // Drag preview.
            paper(page)
                .aspectRatio(PageGeometry.size.width / PageGeometry.size.height, contentMode: .fit)
                .frame(width: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .dropDestination(for: String.self) { items, _ in
            guard selectedPageIDs == nil,
                  let dragged = items.first,
                  let fromIndex = model.pages.firstIndex(where: { $0.id.uuidString == dragged }) else {
                return false
            }
            Task { await model.movePage(from: fromIndex, to: index) }
            return true
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedPageIDs?.contains(id) == true {
            selectedPageIDs?.remove(id)
        } else {
            selectedPageIDs?.insert(id)
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

    /// Renders every page's ink + background once, up front — the manager is
    /// created fresh each time it's shown (`if showPages` in `EditorScreen`),
    /// so this naturally re-runs on every open and never goes stale while a
    /// notebook is being edited underneath it.
    private func loadThumbnails() async {
        for page in model.pages {
            if let filename = page.backgroundPayloadFilename,
               let data = await model.store.mediaData(notebook: model.notebookID, filename: filename),
               let image = UIImage(data: data) {
                backgrounds[page.id] = image
            }
            guard let data = await model.store.pageData(notebook: model.notebookID, page: page.id),
                  let drawing = try? PKDrawing(data: data)
            else { continue }
            let bounds = CGRect(origin: .zero, size: page.logicalSize)
            inkImages[page.id] = drawing.image(from: bounds, scale: displayScale)
        }
    }
}
