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

/// The library's four real tabs. "New" sits between Search and Trash in the
/// bar but is a plain button, not a tab — it never has content of its own.
enum LibraryTab: Hashable {
    case shelves, search, trash, settings
}

/// iPad's library shell: Shelves, Search, a centred `+`, Trash and Settings,
/// as a hand-built bottom bar rather than the system `TabView` chrome.
///
/// The new `Tab`-catalog `TabView` was tried first with `.tabViewStyle(.tabBarOnly)`,
/// on the theory that `.automatic` was choosing iPadOS 18's adaptable-sidebar
/// presentation. It wasn't: iPadOS 18 changed the PLATFORM DEFAULT position for
/// a `TabView`'s own chrome to a floating bar at the TOP of the screen, and
/// `.tabBarOnly` only rules out the sidebar option — it has no lever for which
/// EDGE the bar sits against, because the system no longer offers a "bottom"
/// tab bar on iPad at all. Nothing built on top of that API can be forced
/// bottom, however it's configured — hence a bar that was still on top, still
/// unstyled, after two straight rounds of style flags that never had a chance
/// of working. This bar is ordinary SwiftUI content in a `safeAreaInset`, so
/// its position and its icon+label rendering are ours, not the platform's.
///
/// All four screens stay mounted for as long as the shell is alive — switching
/// tabs only toggles which one is drawn on top and hit-testable — so leaving
/// Search and coming back doesn't lose the query or the scroll position the
/// way tearing the view down and rebuilding it would.
///
/// Trash and Settings are handed `isTab: true` to drop their own "Done"
/// button — there's nothing to dismiss back to, you just tap another tab.
public struct LibraryTabScreen<Destination: View>: View {
    @Environment(\.theme) private var theme

    private let destination: (Notebook, UUID?) -> Destination

    @State private var selectedTab: LibraryTab = .shelves
    @State private var addChoice: AddContentChoice?
    @State private var showCreateSheet = false
    /// Whether the ACTIVE tab currently has a notebook pushed over it —
    /// tracked per tab (only Shelves and Search ever push one) so switching to
    /// a tab that has nothing open doesn't inherit another tab's hidden bar.
    @State private var shelvesDetailOpen = false
    @State private var searchDetailOpen = false

    public init(@ViewBuilder destination: @escaping (Notebook, UUID?) -> Destination) {
        self.destination = destination
    }

    private var isDetailOpen: Bool {
        switch selectedTab {
        case .shelves: shelvesDetailOpen
        case .search: searchDetailOpen
        case .trash, .settings: false
        }
    }

    public var body: some View {
        ZStack {
            LibraryGridScreen(
                addChoice: $addChoice, isDetailOpen: $shelvesDetailOpen, destination: destination
            )
            .opacity(selectedTab == .shelves ? 1 : 0)
            .allowsHitTesting(selectedTab == .shelves)

            LibrarySearchScreen(isDetailOpen: $searchDetailOpen, destination: destination)
                .opacity(selectedTab == .search ? 1 : 0)
                .allowsHitTesting(selectedTab == .search)

            TrashScreen(isTab: true)
                .opacity(selectedTab == .trash ? 1 : 0)
                .allowsHitTesting(selectedTab == .trash)

            SettingsScreen(isTab: true)
                .opacity(selectedTab == .settings ? 1 : 0)
                .allowsHitTesting(selectedTab == .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            if !isDetailOpen {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.28), value: isDetailOpen)
        .sheet(isPresented: $showCreateSheet) {
            AddContentSheet { choice in
                addChoice = choice
                showCreateSheet = false
            }
        }
    }

    private var bottomBar: some View {
        GlassEffectContainer {
            HStack(spacing: 2) {
                tabButton(.shelves, title: "Shelves", systemImage: "books.vertical")
                tabButton(.search, title: "Search", systemImage: "magnifyingglass")
                createButton
                tabButton(.trash, title: "Trash", systemImage: "trash")
                tabButton(.settings, title: "Settings", systemImage: "gearshape")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .dsGlass(in: Capsule(), interactive: true)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .padding(.horizontal, 40)
        .padding(.bottom, 8)
    }

    private func tabButton(_ tab: LibraryTab, title: String, systemImage: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.dsSystem(size: 20, weight: isSelected ? .semibold : .regular))
                Text(title)
                    .font(.dsCaption2.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? theme.accent.color : theme.inkSecondary.color)
            .frame(minWidth: 60, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var createButton: some View {
        Button {
            showCreateSheet = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.dsSystem(size: 30))
                .foregroundStyle(theme.accent.color)
                .frame(minWidth: 60, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New")
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
    /// Reported up so the shell can hide its own bottom bar while a notebook
    /// pushed from a search hit is on screen.
    @Binding var isDetailOpen: Bool

    @State private var opened: LibraryOpenRequest?
    @State private var searchText = ""
    @State private var search = LibrarySearchModel()

    init(isDetailOpen: Binding<Bool>, @ViewBuilder destination: @escaping (Notebook, UUID?) -> Destination) {
        self._isDetailOpen = isDetailOpen
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
                destination(request.notebook, request.pageID)
            }
        }
        .onChange(of: opened) { _, new in isDetailOpen = new != nil }
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
