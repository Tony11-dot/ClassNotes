import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// Which notebook to open, and where in it. A struct rather than a bare
/// `Notebook?` so `navigationDestination(item:)` carries the page too. Shared
/// across every tab that can open a notebook (Shelves, Search).
struct LibraryOpenRequest: Identifiable, Hashable {
    let notebook: Notebook
    let pageID: UUID?
    var id: UUID { notebook.id }
}

/// The library's five tabs. `create` is never actually shown as a tab's
/// content — selecting it is intercepted and turned into a sheet instead, so
/// it's a place in the bar, not a screen.
enum LibraryTab: Hashable {
    case shelves, search, create, trash, settings
}

/// iPad's library shell: a native bottom tab bar (Liquid Glass floating chrome
/// is automatic on this SDK for a stock `TabView`) — Shelves, Search, a
/// centred `+`, Trash and Settings, in that literal order so `+` lands dead
/// centre. The bigger logo lives on the Shelves tab as its page title, not
/// folded into the bar itself.
///
/// Trash and Settings used to be sheets triggered from small buttons buried in
/// a floating toolbar; they're full tabs now, so `TrashScreen`/`SettingsScreen`
/// are handed `isTab: true` to drop their own "Done" button — there's nothing
/// to dismiss back to, you just tap another tab.
public struct LibraryTabScreen<Destination: View>: View {
    private let destination: (Notebook, UUID?) -> Destination

    @State private var selectedTab: LibraryTab = .shelves
    @State private var addChoice: AddContentChoice?
    @State private var showCreateSheet = false

    public init(@ViewBuilder destination: @escaping (Notebook, UUID?) -> Destination) {
        self.destination = destination
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Shelves", systemImage: "books.vertical", value: LibraryTab.shelves) {
                LibraryGridScreen(addChoice: $addChoice, destination: destination)
            }
            Tab("Search", systemImage: "magnifyingglass", value: LibraryTab.search) {
                LibrarySearchScreen(destination: destination)
            }
            Tab("New", systemImage: "plus.circle.fill", value: LibraryTab.create) {
                Color.clear
            }
            Tab("Trash", systemImage: "trash", value: LibraryTab.trash) {
                TrashScreen(isTab: true)
            }
            Tab("Settings", systemImage: "gearshape", value: LibraryTab.settings) {
                SettingsScreen(isTab: true)
            }
        }
        // `.automatic` can present as a top bar or an adaptable sidebar on
        // iPad rather than the classic bottom bar — which is also why it can
        // read as text-only, since those presentations don't draw the same
        // icon+label bottom-bar look every `Tab` here is already built for.
        // Forcing `.tabBarOnly` pins it to the floating Liquid Glass bottom
        // bar the user actually asked for.
        .tabViewStyle(.tabBarOnly)
        // The `create` tab is an ACTION, not a screen: selecting it never
        // actually shows anything — it bounces straight back to whichever tab
        // was showing and opens the creation sheet instead. Doing this in
        // `didSet`-style via `onChange` (rather than a button living outside
        // the TabView) is what keeps `+` in its natural centred position among
        // the other four, matching what the user asked for.
        .onChange(of: selectedTab) { old, new in
            guard new == .create else { return }
            selectedTab = old
            showCreateSheet = true
        }
        .sheet(isPresented: $showCreateSheet) {
            AddContentSheet { choice in
                addChoice = choice
                showCreateSheet = false
            }
        }
    }
}

/// The library's Search tab: its own dedicated screen rather than a modifier
/// living on the grid, so search is reachable as one of the five tabs instead
/// of only via the system-placed field on the Shelves tab.
struct LibrarySearchScreen<Destination: View>: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]

    private let destination: (Notebook, UUID?) -> Destination

    @State private var opened: LibraryOpenRequest?
    @State private var searchText = ""
    @State private var search = LibrarySearchModel()

    init(@ViewBuilder destination: @escaping (Notebook, UUID?) -> Destination) {
        self.destination = destination
    }

    private var liveNotebooks: [Notebook] { notebooks.filter { !$0.isTrashed } }

    var body: some View {
        NavigationStack {
            Group {
                if search.hasQuery || search.isSearching {
                    LibrarySearchResultsView(model: search, notebooks: liveNotebooks) { notebook, pageID in
                        services.repository.touch(notebook)
                        opened = LibraryOpenRequest(notebook: notebook, pageID: pageID)
                    }
                } else {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: "Search your notebooks",
                        message: "Find notebooks and pages by title or by what's actually written on them."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.color)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search notebooks and pages")
            .onChange(of: searchText) { _, query in
                search.search(
                    query, targets: services.repository.searchTargets(),
                    indexer: services.searchIndexer
                )
                // A library that has never been read matches on titles only, and
                // "it can't find my notes" is the impression that leaves. Reading
                // starts the moment someone actually searches.
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    search.indexLibrary(
                        targets: services.repository.searchTargets(),
                        indexer: services.searchIndexer,
                        thenRepeat: query
                    )
                }
            }
            .navigationDestination(item: $opened) { request in
                // A destination pushed inside a tab's own NavigationStack does
                // NOT hide the tab bar by default — without this, the bar sat
                // behind the editor/viewer for as long as it was open.
                destination(request.notebook, request.pageID)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }
}

/// The six ways into a document, as a proper sheet rather than a dropdown menu
/// — the tab bar's `+` has no anchor view a `Menu` could drop out of, since
/// selecting it is intercepted before it ever becomes "the" tab.
struct AddContentSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let onChoose: (AddContentChoice) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(AddContentChoice.allCases) { choice in
                    if choice != .scan || DocumentScannerView.isSupported {
                        Button {
                            onChoose(choice)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: choice.symbolName)
                                    .font(.dsSystem(size: 20))
                                    .foregroundStyle(theme.accent.color)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.title)
                                        .font(.dsSubheadline.weight(.semibold))
                                        .foregroundStyle(theme.ink.color)
                                    Text(choice.subtitle)
                                        .font(.dsCaption)
                                        .foregroundStyle(theme.inkSecondary.color)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
