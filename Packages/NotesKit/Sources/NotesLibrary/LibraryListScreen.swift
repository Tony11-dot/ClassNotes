import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// iPhone library: a read-only list. No creation, no editing — notebooks are
/// made on iPad; here they're browsed, viewed and shared.
public struct LibraryListScreen<Destination: View>: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.paperTone) private var paperTone
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]

    /// The viewer, given the notebook and the page a search hit pointed at.
    private let destination: (Notebook, UUID?) -> Destination

    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showTrash = false
    @State private var selection = LibrarySelection()
    @State private var confirmBulkDelete = false
    @State private var search = LibrarySearchModel()
    @State private var sharedPDF: SharedFile?
    @State private var opened: OpenRequest?

    public init(@ViewBuilder destination: @escaping (Notebook, UUID?) -> Destination) {
        self.destination = destination
    }

    private struct OpenRequest: Identifiable, Hashable {
        let notebook: Notebook
        let pageID: UUID?
        var id: UUID { notebook.id }
    }

    /// The library proper — never anything in the trash.
    private var liveNotebooks: [Notebook] {
        notebooks.filter { !$0.isTrashed }
    }

    private var trashCount: Int { notebooks.filter(\.isTrashed).count }

    /// Favourites first, then everything else — both already in most-recent
    /// order, because that's how the query arrives.
    private var filtered: [Notebook] {
        let live = liveNotebooks
        return live.filter(\.isFavorite) + live.filter { !$0.isFavorite }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if search.hasQuery || search.isSearching {
                    LibrarySearchResultsView(
                        model: search, notebooks: liveNotebooks
                    ) { notebook, pageID in
                        opened = OpenRequest(notebook: notebook, pageID: pageID)
                    }
                } else if liveNotebooks.isEmpty {
                    EmptyStateView(
                        systemImage: "book.closed",
                        title: "No notebooks yet",
                        message: "Notebooks you create on iPad appear here to read and share."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(theme.surface.color)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Notebook.self) { notebook in
                destination(notebook, nil)
            }
            .navigationDestination(item: $opened) { request in
                destination(request.notebook, request.pageID)
            }
            .toolbar {
                BrandTitle()
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Button {
                            showTrash = true
                        } label: {
                            Label(
                                trashCount > 0 ? "Recently Deleted (\(trashCount))" : "Recently Deleted",
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
                if !liveNotebooks.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selection.isActive ? "Done" : "Select") {
                            if selection.isActive {
                                selection.end()
                            } else {
                                selection.beginEmpty()
                            }
                        }
                    }
                }
            }
            // An INSET, not an overlay: iOS 26 puts the search field at the bottom
            // edge on iPhone, and it was landing on top of this bar — which is
            // why its buttons did nothing.
            .safeAreaInset(edge: .bottom) {
                if selection.isActive {
                    LibrarySelectionBar(
                        selection: selection,
                        shelves: [],
                        allIDs: filtered.map(\.id),
                        onDelete: { confirmBulkDelete = true },
                        onMove: { _ in }
                    )
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.28), value: selection.isActive)
            .confirmationDialog(
                selection.count == 1
                    ? "Delete 1 notebook? You can get it back from Recently Deleted for 30 days."
                    : "Delete \(selection.count) notebooks? You can get them back from Recently Deleted for 30 days.",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let doomed = selection.selected(from: filtered)
                    selection.end()
                    try? services.repository.moveToTrash(doomed)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        // iOS 26 places search at the bottom edge on iPhone automatically.
        .searchable(text: $searchText, prompt: "Search notebooks and pages")
        .onChange(of: searchText) { _, query in
            search.search(
                query, targets: services.repository.searchTargets(),
                indexer: services.searchIndexer
            )
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                search.indexLibrary(
                    targets: services.repository.searchTargets(),
                    indexer: services.searchIndexer,
                    thenRepeat: query
                )
            }
        }
        .sheet(isPresented: $showSettings) { SettingsScreen() }
        .sheet(isPresented: $showTrash) { TrashScreen() }
        .sheet(item: $sharedPDF) { file in
            ShareSheet(items: [file.url])
        }
    }

    /// Renders a notebook to a PDF and hands it to the share sheet. The phone is
    /// a reading device for these notebooks, and reading them somewhere else —
    /// printing, emailing to a teacher — is most of what a phone is for here.
    private func exportPDF(_ notebook: Notebook) {
        Task { @MainActor in
            let exporter = NotebookExporter(
                store: services.documentStore, theme: theme, paperTone: paperTone
            )
            sharedPDF = await exporter.pdfFile(notebook: notebook).map(SharedFile.init(url:))
        }
    }

    private var list: some View {
        List(filtered) { notebook in
            row(notebook)
                .listRowBackground(theme.surfaceRaised.color)
        }
        .scrollContentBackground(.hidden)
    }

    /// While selecting, the row picks up instead of navigating — a NavigationLink
    /// would push the viewer out from under the tick the user just tapped.
    @ViewBuilder
    private func row(_ notebook: Notebook) -> some View {
        if selection.isActive {
            Button {
                selection.toggle(notebook.id)
            } label: {
                rowContent(notebook)
                    .librarySelectable(isActive: true, isSelected: selection.contains(notebook.id))
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: notebook) {
                rowContent(notebook)
            }
            .contextMenu {
                Button {
                    selection.begin(with: notebook.id)
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                Button {
                    try? services.repository.toggleFavorite(notebook)
                } label: {
                    Label(
                        notebook.isFavorite ? "Remove from favourites" : "Add to favourites",
                        systemImage: notebook.isFavorite ? "star.slash" : "star"
                    )
                }
                Button {
                    exportPDF(notebook)
                } label: {
                    Label("Export as PDF", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    try? services.repository.moveToTrash(notebook)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func rowContent(_ notebook: Notebook) -> some View {
        HStack(spacing: 14) {
                    NotebookCoverTile(notebook: notebook, showsTitle: false)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(notebook.title)
                        } icon: {
                            if notebook.kind != .notebook {
                                Image(systemName: notebook.kind.symbolName)
                            }
                        }
                            .font(.dsBody.weight(.medium))
                            .foregroundStyle(theme.ink.color)
                        Text(notebook.updatedAt, format: .dateTime.day().month().year())
                            .font(.dsCaption)
                            .foregroundStyle(theme.inkSecondary.color)
            }
            Spacer(minLength: 8)
            if notebook.isFavorite {
                Image(systemName: "star.fill")
                    .font(.dsFootnote)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityLabel("Favourite")
            }
        }
    }
}
