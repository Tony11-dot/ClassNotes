import Foundation
import NotesModels

/// One notebook that matched a library search, with the pages inside it that
/// matched.
public struct NotebookSearchResult: Sendable, Identifiable, Equatable {
    public var id: UUID { notebookID }
    public let notebookID: UUID
    public let title: String
    /// The query is in the notebook's own name.
    public let matchesTitle: Bool
    /// Matching pages, best first. Empty when only the title matched.
    public let pageHits: [NoteSearch.Hit]

    public init(
        notebookID: UUID, title: String, matchesTitle: Bool, pageHits: [NoteSearch.Hit]
    ) {
        self.notebookID = notebookID
        self.title = title
        self.matchesTitle = matchesTitle
        self.pageHits = pageHits
    }

    /// How this result sorts. A notebook whose NAME matches is what the user was
    /// most likely reaching for — someone typing "Physics" wants the Physics
    /// book, not the page of a chemistry book where they wrote the word once.
    public var rank: Int {
        (matchesTitle ? 1_000 : 0) + (pageHits.first?.score ?? 0)
    }
}

/// The notebooks a library search runs over: just enough of each row to search
/// and to show a result, carried out of `@MainActor` SwiftData land so the
/// indexer can work off the main thread.
public struct SearchTarget: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public extension SearchIndexer {
    /// Searches titles and page content across the given notebooks.
    ///
    /// Reads only indexes that already EXIST — it never builds one, so typing in
    /// the search field can't stall behind recognising a library. Building is
    /// `indexAll`, which the library runs in the background; until a notebook has
    /// been read, it still matches on its title.
    func search(_ query: String, across targets: [SearchTarget]) async -> [NotebookSearchResult] {
        let terms = NoteSearch.terms(in: query)
        guard !terms.isEmpty else { return [] }

        var results: [NotebookSearchResult] = []
        for target in targets {
            let matchesTitle = NoteSearch.matches(terms, in: target.title)
            let index = await store.searchIndex(for: target.id)
            let hits = NoteSearch.search(query, in: index)
            guard matchesTitle || !hits.isEmpty else { continue }
            results.append(NotebookSearchResult(
                notebookID: target.id,
                title: target.title,
                matchesTitle: matchesTitle,
                pageHits: hits
            ))
        }
        return results.sorted { $0.rank > $1.rank }
    }

    /// Reads every notebook that needs it, one at a time.
    ///
    /// Deliberately serial: recognition is expensive, and a library-wide parallel
    /// pass would fight the editor for the CPU the moment someone starts writing.
    /// `onProgress` reports notebooks finished, so the UI can say what it's doing
    /// instead of showing an empty result list that quietly fills in.
    func indexAll(_ targets: [SearchTarget], onProgress: (@Sendable (Int, Int) -> Void)? = nil) async {
        for (offset, target) in targets.enumerated() {
            await index(notebook: target.id)
            onProgress?(offset + 1, targets.count)
        }
    }
}
