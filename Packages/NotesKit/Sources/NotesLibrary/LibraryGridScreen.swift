import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// iPad library: themed cover grid with a floating glass toolbar.
///
/// The editor destination is injected by the routing layer — this module never
/// imports NotesEditor, so the iPhone build path can't reach editing code.
public struct LibraryGridScreen<Destination: View>: View {
    @Environment(AppServices.self) var services
    @Environment(\.theme) var theme
    @Environment(\.paperTone) private var paperTone
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]
    @Query(sort: \Shelf.sortIndex) var shelves: [Shelf]

    /// The editor, given the notebook and — when the user came from a search hit
    /// or a bookmark — the page they were actually looking for.
    private let destination: (Notebook, UUID?) -> Destination
    /// Owned by `LibraryTabScreen`: the tab bar's own `+` sets this the same way
    /// the empty-state's "New notebook" button does, so both trigger the SAME
    /// creation flow below rather than two separate ones.
    @Binding var addChoice: AddContentChoice?
    /// Reported up so the shell can hide its own bottom bar while a notebook
    /// pushed from this tab is on screen.
    @Binding var isDetailOpen: Bool

    @State var opened: LibraryOpenRequest?
    @State var renameTarget: Notebook?
    @State var renameText = ""
    @State var deleteTarget: Notebook?
    @State var selectedShelf: ShelfFilter = .all
    @State var showNewShelf = false
    @State var showAddBooks = false
    @State var selection = LibrarySelection()
    @State var confirmBulkDelete = false
    @State var sharedPDF: SharedFile?
    @State var exporting = false

    public init(
        addChoice: Binding<AddContentChoice?>,
        isDetailOpen: Binding<Bool>,
        @ViewBuilder destination: @escaping (Notebook, UUID?) -> Destination
    ) {
        self._addChoice = addChoice
        self._isDetailOpen = isDetailOpen
        self.destination = destination
    }

    /// What the shelf bar is filtering by. Favourites is a filter, not a shelf —
    /// a notebook can be starred and still live on a shelf.
    enum ShelfFilter: Hashable {
        case all
        case favorites
        case shelf(UUID)
    }

    /// Everything in the library: never anything in the trash.
    var liveNotebooks: [Notebook] {
        notebooks.filter { !$0.isTrashed }
    }

    var visibleNotebooks: [Notebook] {
        switch selectedShelf {
        case .all:
            return liveNotebooks
        case .favorites:
            return liveNotebooks.filter(\.isFavorite)
        case .shelf(let id):
            return liveNotebooks.filter { $0.shelfID == id }
        }
    }

    var favoritesCount: Int { liveNotebooks.filter(\.isFavorite).count }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !shelves.isEmpty || favoritesCount > 0 {
                    shelfBar
                }
                Group {
                    if visibleNotebooks.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.color)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                BrandTitle(height: 88)
            }
            .navigationDestination(item: $opened) { request in
                destination(request.notebook, request.pageID)
            }
            .onChange(of: opened) { _, new in isDetailOpen = new != nil }
            .overlay(alignment: .bottom) {
                if !selection.isActive { floatingToolbar }
            }
            // The bar is a safe-area INSET, not an overlay: it reserves its own
            // room instead of floating over whatever the system has already put
            // at the bottom edge, so nothing lands on top of its buttons.
            .safeAreaInset(edge: .bottom) {
                if selection.isActive {
                    LibrarySelectionBar(
                        selection: selection,
                        shelves: shelves,
                        allIDs: visibleNotebooks.map(\.id),
                        onDelete: { confirmBulkDelete = true },
                        onMove: { shelfID in
                            try? services.repository.setShelf(
                                shelfID, for: selection.selected(from: visibleNotebooks)
                            )
                            selection.end()
                        }
                    )
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.28), value: selection.isActive)
        }
        .addContentFlows(choice: $addChoice, shelfID: activeShelfID) { notebook in
            opened = LibraryOpenRequest(notebook: notebook, pageID: nil)
        }
        .sheet(isPresented: $showNewShelf) { NewShelfSheet() }
        .sheet(item: $sharedPDF) { file in
            ShareSheet(items: [file.url])
        }
        .sheet(isPresented: $showAddBooks) {
            if let activeShelfID { AddBooksToShelfSheet(shelfID: activeShelfID) }
        }
        .alert("Rename notebook", isPresented: renameAlertBinding) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    try? services.repository.rename(target, to: renameText)
                }
                renameTarget = nil
            }
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.title ?? "")”? You can get it back from Recently Deleted for 30 days.",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Notebook", role: .destructive) {
                if let target = deleteTarget {
                    try? services.repository.moveToTrash(target)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
        .confirmationDialog(
            selection.count == 1
                ? "Delete 1 notebook? You can get it back from Recently Deleted for 30 days."
                : "Delete \(selection.count) notebooks? You can get them back from Recently Deleted for 30 days.",
            isPresented: $confirmBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let doomed = selection.selected(from: visibleNotebooks)
                selection.end()
                try? services.repository.moveToTrash(doomed)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The shelf a new notebook lands on: only a real shelf counts. "Favourites"
    /// is a filter, so creating a book while it's selected must not try to file
    /// the book onto a shelf that doesn't exist.
    var activeShelfID: UUID? {
        if case .shelf(let id) = selectedShelf { return id }
        return nil
    }

    /// Renders a notebook to a PDF and hands it to the share sheet.
    func exportPDF(_ notebook: Notebook) {
        guard !exporting else { return }
        exporting = true
        Task { @MainActor in
            let exporter = NotebookExporter(
                store: services.documentStore, theme: theme, paperTone: paperTone
            )
            sharedPDF = await exporter.pdfFile(notebook: notebook).map(SharedFile.init(url:))
            exporting = false
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 28)],
                spacing: 28
            ) {
                ForEach(visibleNotebooks) { notebook in
                    coverCell(notebook)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        // Explicit "get the latest" — a notebook drawn on another device
        // since the last launch/foreground shouldn't need waiting for.
        .refreshable { await services.refreshRemoteLibrary(force: true) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if selectedShelf == .favorites {
            EmptyStateView(
                systemImage: "star",
                title: "No favourites yet",
                message: "Press and hold a notebook to star it, and it'll wait for you here."
            )
        } else if activeShelfID != nil {
            VStack(spacing: 20) {
                EmptyStateView(
                    systemImage: "tray",
                    title: "This shelf is empty",
                    message: "Add notebooks you already have, or create a new one right here."
                )
                HStack(spacing: 12) {
                    Button {
                        showAddBooks = true
                    } label: {
                        Label("Add books", systemImage: "plus.rectangle.on.folder")
                            .font(.dsSubheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(theme.accent.color, in: Capsule())
                            .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                    }
                    Button {
                        addChoice = .notebook
                    } label: {
                        Label("New notebook", systemImage: "plus")
                            .font(.dsSubheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(theme.surfaceRaised.color, in: Capsule())
                            .foregroundStyle(theme.ink.color)
                    }
                }
                .buttonStyle(.plain)
            }
        } else {
            EmptyStateView(
                systemImage: "book.closed",
                title: "No notebooks yet",
                message: "Tap + for a quick note, a full notebook, a whiteboard, or to bring in a photo, file or scan."
            )
        }
    }

    // Creation, Trash and Settings moved to `LibraryTabScreen`'s tab bar; this
    // stays for what's specific to THIS tab — managing shelves.
    private var floatingToolbar: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                DSGlassIconButton("New shelf", systemImage: "tray.and.arrow.down") {
                    showNewShelf = true
                }
                if activeShelfID != nil {
                    DSGlassIconButton("Add books to shelf", systemImage: "plus.rectangle.on.folder") {
                        showAddBooks = true
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .dsGlass(in: Capsule(), interactive: true)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .padding(.bottom, 24)
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }
}
