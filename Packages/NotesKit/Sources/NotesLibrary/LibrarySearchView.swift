import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// Runs library search off the typing.
///
/// Every keystroke cancels the search in flight and starts a new one after a
/// short pause. Searching on each character means recognition-sized work for
/// letters nobody finished typing; searching only on Return means a search box
/// that feels broken. The pause is the whole of the difference.
@MainActor
@Observable
public final class LibrarySearchModel {
    public private(set) var results: [NotebookSearchResult] = []
    /// The query the current `results` belong to, so a stale list is never shown
    /// against a newer query.
    public private(set) var settledQuery = ""
    public private(set) var isSearching = false
    /// How far the background read of the library has got, while it's running.
    public private(set) var indexed: (done: Int, total: Int)?

    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

    static let debounce = Duration.milliseconds(220)

    public init() {}

    public var hasQuery: Bool { !settledQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    public func search(_ query: String, targets: [SearchTarget], indexer: SearchIndexer) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            settledQuery = ""
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let found = await indexer.search(trimmed, across: targets)
            guard !Task.isCancelled else { return }
            self?.results = found
            self?.settledQuery = trimmed
            self?.isSearching = false
        }
    }

    /// Reads any notebooks that haven't been read yet, so their handwriting
    /// becomes searchable. Safe to call repeatedly — pages already indexed are
    /// skipped inside the indexer.
    public func indexLibrary(
        targets: [SearchTarget], indexer: SearchIndexer, thenRepeat query: String
    ) {
        guard indexTask == nil, !targets.isEmpty else { return }
        indexed = (0, targets.count)
        indexTask = Task { [weak self] in
            await indexer.indexAll(targets) { done, total in
                Task { @MainActor in self?.indexed = (done, total) }
            }
            guard !Task.isCancelled else { return }
            self?.indexed = nil
            self?.indexTask = nil
            // Re-run the query: the answer may have changed under it.
            self?.search(query, targets: targets, indexer: indexer)
        }
    }

    public func cancel() {
        searchTask?.cancel()
        indexTask?.cancel()
        indexTask = nil
        results = []
        settledQuery = ""
        isSearching = false
        indexed = nil
    }
}

/// The results list: notebooks that matched, each with the pages inside them
/// that matched and the words around the match.
struct LibrarySearchResultsView: View {
    @Environment(\.theme) private var theme

    let model: LibrarySearchModel
    let notebooks: [Notebook]
    /// Opening a result: the notebook, and the page it was found on (nil when
    /// only the title matched).
    let onOpen: (Notebook, UUID?) -> Void

    private func notebook(_ id: UUID) -> Notebook? {
        notebooks.first { $0.id == id }
    }

    var body: some View {
        List {
            if let indexed = model.indexed {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading your handwriting… \(indexed.done) of \(indexed.total)")
                            .font(.dsFootnote)
                            .foregroundStyle(theme.inkSecondary.color)
                    }
                }
            }
            if model.results.isEmpty, !model.isSearching, model.hasQuery {
                Section {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: "Nothing found",
                        message: "Search looks at notebook names and at the words on their pages."
                    )
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(model.results) { result in
                if let book = notebook(result.notebookID) {
                    Section {
                        Button {
                            onOpen(book, nil)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: book.kind.symbolName)
                                    .foregroundStyle(theme.accent.color)
                                Text(book.title)
                                    .font(.dsHeadline)
                                    .foregroundStyle(theme.ink.color)
                                Spacer()
                                if result.matchesTitle {
                                    Text("Name")
                                        .font(.dsCaption2)
                                        .foregroundStyle(theme.inkSecondary.color)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        ForEach(result.pageHits.prefix(4)) { hit in
                            Button {
                                onOpen(book, hit.pageID)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "text.page")
                                        .font(.dsFootnote)
                                        .foregroundStyle(theme.inkSecondary.color)
                                    Text(hit.snippet)
                                        .font(.dsFootnote)
                                        .foregroundStyle(theme.ink.color)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.surface.color)
    }
}
