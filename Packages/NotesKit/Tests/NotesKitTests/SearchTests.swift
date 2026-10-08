import CoreGraphics
import Foundation
import NotesModels
import Testing
import UIKit
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

    @Test("An index from before languages were recorded reads as English, not as unread")
    func legacyIndexIsEnglish() throws {
        let legacy = Data(#"{"version":1,"pages":[]}"#.utf8)
        let index = try JSONDecoder().decode(SearchIndex.self, from: legacy)
        #expect(index.language == nil)
        // Every pre-existing index was read with the English model, so an English
        // user must not have their whole library read again for nothing…
        #expect(index.isRead(in: "en-US"))
        // …and a Hebrew user's must be, because it was read in the wrong language.
        #expect(!index.isRead(in: "he-IL"))
    }
}

/// The language the indexer is asked to read in, changeable mid-test.
private actor RecognitionLanguage {
    var code: String
    init(_ code: String) { self.code = code }
    func set(_ code: String) { self.code = code }
}

@Suite("Search reads in the user's language")
struct SearchLanguageTests {
    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnote-search-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Changing the recognition language re-reads every page once, in the new language")
    func languageChangeRereads() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        let manifest = try await store.createDocument(id: id, style: PageStyle(template: .ruled))
        let page = try #require(manifest.pages.first?.id)
        _ = try await store.setElements(
            [PageElement(kind: .text, x: 0, y: 0, width: 100, height: 40, text: "photosynthesis")],
            notebook: id, page: page
        )
        let language = RecognitionLanguage("en-US")
        let indexer = SearchIndexer(store: store) { await language.code }

        let first = await indexer.index(notebook: id)
        #expect(first.language == "en-US")
        #expect(first.text(for: page) == "photosynthesis")
        let firstRead = try #require(first.pages.first?.indexedAt)

        // Nothing changed: the page is not read again.
        try await Task.sleep(for: .milliseconds(20))
        let again = await indexer.index(notebook: id)
        #expect(again.pages.first?.indexedAt == firstRead)

        // The user switched to Hebrew: the English reading is stale.
        await language.set("he-IL")
        try await Task.sleep(for: .milliseconds(20))
        let hebrew = await indexer.index(notebook: id)
        #expect(hebrew.language == "he-IL")
        #expect((hebrew.pages.first?.indexedAt ?? .distantPast) > firstRead)
        // And it was persisted, so the next launch doesn't read it all over again.
        #expect(await store.searchIndex(for: id).language == "he-IL")
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

@Suite("Search matching is byte-fast and still means the same thing")
struct SearchMatchingTests {

    private func index(_ texts: [String]) -> (SearchIndex, [UUID]) {
        var index = SearchIndex(language: "en-US")
        let ids = texts.map { _ in UUID() }
        for (id, text) in zip(ids, texts) { index.set(text, for: id) }
        return (index, ids)
    }

    @Test("The near-the-top bonus counts characters, so a Greek page isn't held to half the distance")
    func nearTopCountsCharacters() {
        // 60 Greek letters (two bytes each) then the term: 60 characters in,
        // 120 bytes in. Both pages mention it once; both earn the bonus.
        let greek = String(repeating: "α", count: 60) + " mitochondria"
        let latin = String(repeating: "a", count: 60) + " mitochondria"
        let (index, _) = index([greek, latin])
        let hits = NoteSearch.search("mitochondria", in: index)
        #expect(hits.map(\.score) == [3, 3])
    }

    @Test("Accents and case are folded on both sides, and repeats are counted without overlap")
    func foldsAndCounts() {
        let (index, ids) = index(["Café CAFÉ cafe", "aaaa", "nothing here"])
        let cafe = NoteSearch.search("cafe", in: index)
        #expect(cafe.map(\.pageID) == [ids[0]])
        #expect(cafe.first?.score == 3 + 2)
        #expect(NoteSearch.search("aa", in: index).first?.score == 2 + 2, "aaaa holds two, not three")
        #expect(NoteSearch.search("cafe nothing", in: index).isEmpty, "every term must be on the page")
    }

    @Test("A snippet is still cut around the match when it's finally shown")
    func lazySnippet() {
        let (index, _) = index(["Intro text. " + String(repeating: "filler ", count: 30) + "the Krebs cycle runs here"])
        let snippet = NoteSearch.search("krebs", in: index).first?.snippet ?? ""
        #expect(snippet.contains("Krebs cycle"))
        #expect(snippet.hasPrefix("…"))
    }
}

@Suite("Imported pages are searchable")
struct ImportedPageSearchTests {

    private func handout() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Mitochondria and the Krebs cycle" as NSString).draw(
                at: CGPoint(x: 60, y: 80),
                withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .semibold)]
            )
        }
    }

    private func importedNotebook() async throws -> (DocumentStore, UUID, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-printed-\(UUID().uuidString)", isDirectory: true)
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        try await store.createDocument(id: id, style: PageStyle(template: .blank))
        _ = try await store.importPDF(data: handout(), notebook: id, at: 0)
        return (store, id, root)
    }

    @Test("Words printed on an imported PDF page are found by search")
    func printedTextIsIndexed() async throws {
        let (store, id, root) = try await importedNotebook()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexer = SearchIndexer(store: store) { "en-US" }
        let index = await indexer.index(notebook: id)
        let page = try await store.manifest(for: id).pages[0].id
        let text = NoteSearch.fold(index.text(for: page) ?? "")
        #expect(text.contains("krebs"))
        #expect(!NoteSearch.search("krebs cycle", in: index).isEmpty)
    }

    @Test("An index written before backgrounds were read reads imported pages once more")
    func oldIndexRereadsImportedPages() async throws {
        let (store, id, root) = try await importedNotebook()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = try await store.manifest(for: id).pages.map(\.id)
        // What a v1 build left: every page read, none of them anything.
        var old = SearchIndex(version: 1, language: "en-US")
        for page in pages { old.set("", for: page, at: .now.addingTimeInterval(3_600)) }
        try await store.saveSearchIndex(old, for: id)

        let index = await SearchIndexer(store: store) { "en-US" }.index(notebook: id)
        #expect(index.version == SearchIndex.currentVersion)
        #expect(NoteSearch.fold(index.text(for: pages[0]) ?? "").contains("krebs"))
        #expect(index.text(for: pages[1]) == "", "a page with no background isn't read again for nothing")
    }

    @Test("Printed words come after the user's own, so a snippet favours what they wrote")
    func printedComesLast() {
        let text = SearchIndexer.pageText(
            elements: [PageElement(kind: .text, x: 0, y: 0, width: 10, height: 10, text: "my note")],
            recognized: "ink words", printed: "printed words"
        )
        #expect(text == "my note\nink words\nprinted words")
    }
}
