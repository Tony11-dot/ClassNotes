import CoreGraphics
import Foundation
import NotesModels
import Testing
@testable import NotesServices

/// Matching, ranking and snippets — the whole of what "find this in my notes"
/// does, tested without a document, a page or Vision.
@Suite("Searching inside notes")
struct NoteSearchTests {
    @Test("Every word in the query has to appear")
    func requiresAllTerms() {
        let terms = NoteSearch.terms(in: "photosynthesis chlorophyll")
        #expect(terms == ["photosynthesis", "chlorophyll"])
        #expect(NoteSearch.matches(terms, in: "chlorophyll drives photosynthesis"))
        #expect(!NoteSearch.matches(terms, in: "photosynthesis needs light"))
    }

    @Test("An empty query matches nothing — it must never match everything")
    func emptyQueryMatchesNothing() {
        // The dangerous failure: treating "no terms" as "no filter", which would
        // make an empty search box list the entire library as hits.
        #expect(NoteSearch.terms(in: "   ").isEmpty)
        #expect(!NoteSearch.matches([], in: "anything at all"))
        #expect(NoteSearch.search("", in: index(["a": "anything at all"])).isEmpty)
    }

    @Test("Case and accents are ignored — handwriting spells neither reliably")
    func foldsCaseAndAccents() {
        let terms = NoteSearch.terms(in: "Résumé")
        #expect(NoteSearch.matches(terms, in: "my resume for the summer job"))
        #expect(NoteSearch.matches(NoteSearch.terms(in: "NEWTON"), in: "newton's second law"))
    }

    @Test("The page that says it most comes first")
    func ranksByOccurrences() {
        let index = index([
            "sparse": "a single mention of mitosis somewhere near the end of this page",
            "dense": "mitosis mitosis mitosis"
        ])
        let hits = NoteSearch.search("mitosis", in: index)
        #expect(hits.count == 2)
        #expect(hits.first?.score ?? 0 > hits.last?.score ?? 0)
    }

    @Test("A snippet is cut around the match, not off the top of the page")
    func snippetSurroundsTheMatch() {
        let text = String(repeating: "padding ", count: 20) + "the mitochondrion is the powerhouse"
        let snippet = NoteSearch.snippet(of: text, around: ["mitochondrion"])
        #expect(snippet.contains("mitochondrion"))
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.count < text.count)
    }

    @Test("A snippet is cut around the EARLIEST term, whatever order they were typed")
    func snippetUsesTheEarliestTerm() {
        let text = "alpha " + String(repeating: "filler ", count: 30) + "omega"
        // "omega" is typed first but appears last; the snippet should still open
        // at "alpha", which is where the page's answer actually starts.
        let snippet = NoteSearch.snippet(of: text, around: ["omega", "alpha"])
        #expect(snippet.contains("alpha"))
        #expect(!snippet.hasPrefix("…"))
    }

    @Test("A snippet reads as one line, whatever the page looked like")
    func snippetFlattensNewlines() {
        let snippet = NoteSearch.snippet(of: "first line\nsecond line\nthird", around: ["second"])
        #expect(!snippet.contains("\n"))
        #expect(snippet.contains("second line"))
    }

    @Test("Matching inside the page never slides off the end of it")
    func snippetSurvivesAMatchAtTheEnd() {
        // Regression guard for measuring an offset in a folded copy and applying
        // it to the original: folding can change a string's length, and the two
        // then no longer line up.
        let text = "beginning of the page \u{fb01}nally the answer is oxidation"
        let snippet = NoteSearch.snippet(of: text, around: ["oxidation"])
        #expect(snippet.contains("oxidation"))
    }

    private func index(_ pages: [String: String]) -> SearchIndex {
        var index = SearchIndex()
        // Deterministic ids so a failure names the same page every run.
        for (name, text) in pages.sorted(by: { $0.key < $1.key }) {
            index.set(text, for: UUID(uuidString: uuid(for: name)) ?? UUID())
        }
        return index
    }

    private func uuid(for name: String) -> String {
        let hash = abs(name.hashValue) % 1000
        return String(format: "00000000-0000-0000-0000-%012d", hash)
    }
}

@Suite("The search index")
struct SearchIndexTests {
    @Test("Setting a page's text replaces it rather than piling up copies")
    func setReplaces() {
        let page = UUID()
        var index = SearchIndex()
        index.set("first reading", for: page)
        index.set("second reading", for: page)
        #expect(index.pages.count == 1)
        #expect(index.text(for: page) == "second reading")
    }

    @Test("A deleted page stops turning up in results")
    func pruneDropsDeletedPages() {
        let kept = UUID()
        let gone = UUID()
        var index = SearchIndex()
        index.set("still here", for: kept)
        index.set("deleted", for: gone)

        index.prune(toPages: [kept])

        #expect(index.pages.map(\.id) == [kept])
        #expect(index.text(for: gone) == nil)
    }

    @Test("A page is re-read only when its ink is newer than the reading")
    func reindexFollowsTheInk() {
        let page = UUID()
        let read = Date(timeIntervalSince1970: 1_000)
        var index = SearchIndex()
        index.set("words", for: page, at: read)

        #expect(!index.needsReindex(page, changedAt: read.addingTimeInterval(-1)))
        #expect(index.needsReindex(page, changedAt: read.addingTimeInterval(1)))
        // A page the index has never seen always needs reading.
        #expect(index.needsReindex(UUID(), changedAt: read))
    }

    @Test("An index survives a round trip through JSON")
    func codableRoundTrip() throws {
        let page = UUID()
        var index = SearchIndex()
        index.set("chlorophyll", for: page)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SearchIndex.self, from: encoder.encode(index))

        #expect(decoded.text(for: page) == "chlorophyll")
        #expect(decoded.version == SearchIndex.currentVersion)
    }
}

@Suite("What a page contributes to search")
struct PageTextTests {
    @Test("Typed text comes before recognised handwriting")
    func typedTextLeadsTheEntry() {
        // Text boxes are exact and recognition is a guess, so when both contain
        // the query it's the exact copy the snippet gets cut from.
        let text = SearchIndexer.pageText(
            elements: [element(kind: .text, text: "Chapter 4: Redox")],
            recognized: "chapter 4 red ox"
        )
        #expect(text.hasPrefix("Chapter 4: Redox"))
        #expect(text.contains("chapter 4 red ox"))
    }

    @Test("Links and files are findable by what they were called")
    func namesAreIndexed() {
        let text = SearchIndexer.pageText(
            elements: [
                element(kind: .link, displayName: "Khan Academy", urlString: "https://khan.org/x"),
                element(kind: .file, displayName: "past paper.pdf")
            ],
            recognized: ""
        )
        #expect(text.contains("Khan Academy"))
        #expect(text.contains("https://khan.org/x"))
        #expect(text.contains("past paper.pdf"))
    }

    @Test("Things with nothing to say contribute nothing")
    func silentElementsAreSkipped() {
        let text = SearchIndexer.pageText(
            elements: [
                element(kind: .image), element(kind: .audio),
                element(kind: .tape), element(kind: .fill)
            ],
            recognized: ""
        )
        #expect(text.isEmpty)
    }

    @Test("A page nothing could be read from indexes as empty, not as junk")
    func emptyPageIsEmpty() {
        #expect(SearchIndexer.pageText(elements: [], recognized: "   \n  ").isEmpty)
    }

    @Test("Reading scale never blows a big page up past the ceiling")
    func renderScaleIsCapped() {
        // A modest page gets the full magnification handwriting needs...
        #expect(SearchIndexer.renderScale(for: CGSize(width: 768, height: 1024)) == 3)
        // ...and a huge one is held to a bitmap that can actually be produced.
        let huge = SearchIndexer.renderScale(for: CGSize(width: 4000, height: 6000))
        #expect(huge < 1.01)
        #expect(6000 * huge <= SearchIndexer.maximumPageSide + 1)
    }

    private func element(
        kind: PageElement.Kind,
        text: String? = nil,
        displayName: String? = nil,
        urlString: String? = nil
    ) -> PageElement {
        PageElement(
            kind: kind, x: 0, y: 0, width: 10, height: 10,
            displayName: displayName, text: text, urlString: urlString
        )
    }
}

@Suite("Ranking a library search")
struct LibrarySearchRankingTests {
    @Test("A notebook whose NAME matches outranks one that merely mentions it")
    func titleMatchesWinTheTop() {
        let byName = NotebookSearchResult(
            notebookID: UUID(), title: "Physics", matchesTitle: true, pageHits: []
        )
        let byContent = NotebookSearchResult(
            notebookID: UUID(), title: "Chemistry", matchesTitle: false,
            pageHits: [NoteSearch.Hit(pageID: UUID(), snippet: "physics", score: 9)]
        )
        #expect(byName.rank > byContent.rank)
    }

    @Test("Between two content matches, the stronger one wins")
    func strongerContentWins() {
        let weak = NotebookSearchResult(
            notebookID: UUID(), title: "A", matchesTitle: false,
            pageHits: [NoteSearch.Hit(pageID: UUID(), snippet: "x", score: 1)]
        )
        let strong = NotebookSearchResult(
            notebookID: UUID(), title: "B", matchesTitle: false,
            pageHits: [NoteSearch.Hit(pageID: UUID(), snippet: "x", score: 8)]
        )
        #expect(strong.rank > weak.rank)
    }
}
