import Foundation

/// What a notebook's pages SAY, kept beside the ink so the library can search
/// inside notebooks without opening them.
///
/// Handwriting isn't text until something reads it, and reading every page of
/// every notebook on every keystroke is not a search box, it's a hang. So the
/// reading is done once — when a page is put down — and the result is cached
/// here, in `search.json` inside the document package. Losing this file costs
/// nothing but a re-read: it is derived data, never a source of truth, which is
/// why it lives outside the manifest and is never repaired the way ink is.
public struct SearchIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var pages: [PageText]
    /// The recognition language the handwriting was read in (`nil` in an index
    /// written before this was recorded — those were all read as English).
    public var language: String?

    public init(
        version: Int = SearchIndex.currentVersion, pages: [PageText] = [], language: String? = nil
    ) {
        self.version = version
        self.pages = pages
        self.language = language
    }

    /// Whether this index's handwriting was read in `code`. An index from before
    /// the language was recorded was read in English, so it counts as `en-US`
    /// rather than forcing every English notebook to be read again for nothing.
    public func isRead(in code: String) -> Bool {
        (language ?? "en-US") == code
    }

    /// One page's readable content: the words in its text boxes plus whatever
    /// handwriting recognition made of its ink.
    public struct PageText: Codable, Sendable, Equatable, Identifiable {
        /// The page's own id.
        public var id: UUID
        public var text: String
        public var indexedAt: Date

        public init(id: UUID, text: String, indexedAt: Date = .now) {
            self.id = id
            self.text = text
            self.indexedAt = indexedAt
        }
    }

    public func text(for page: UUID) -> String? {
        pages.first { $0.id == page }?.text
    }

    public mutating func set(_ text: String, for page: UUID, at date: Date = .now) {
        let entry = PageText(id: page, text: text, indexedAt: date)
        if let index = pages.firstIndex(where: { $0.id == page }) {
            pages[index] = entry
        } else {
            pages.append(entry)
        }
    }

    /// Drops entries for pages that no longer exist, so a deleted page stops
    /// turning up in results.
    public mutating func prune(toPages ids: [UUID]) {
        let live = Set(ids)
        pages.removeAll { !live.contains($0.id) }
    }

    /// Whether this page needs re-reading because its ink changed after the last
    /// index. A page whose entry is missing always does.
    public func needsReindex(_ page: UUID, changedAt: Date) -> Bool {
        guard let entry = pages.first(where: { $0.id == page }) else { return true }
        return entry.indexedAt < changedAt
    }
}

/// Matching and ranking for "find this in my notes". Pure, so the whole of
/// search's behaviour is testable without a document, a page or Vision.
public enum NoteSearch {
    /// One page that matched, with the words around the match to show in the
    /// result row.
    public struct Hit: Sendable, Equatable, Identifiable {
        public var id: UUID { pageID }
        public let pageID: UUID
        /// Higher is better. Ranking is by score, then by page order.
        public let score: Int
        private let source: HitSnippetSource

        /// Cut when it's SHOWN, not when the page matched: a common word
        /// matches hundreds of pages, a result row shows four, and building
        /// every snippet up front was a third of what such a search cost.
        public var snippet: String {
            switch source {
            case .fixed(let snippet): snippet
            case .page(let text, let terms): NoteSearch.snippet(of: text, around: terms)
            }
        }

        public init(pageID: UUID, snippet: String, score: Int) {
            self.pageID = pageID
            self.score = score
            self.source = .fixed(snippet)
        }

        init(pageID: UUID, text: String, terms: [String], score: Int) {
            self.pageID = pageID
            self.score = score
            self.source = .page(text: text, terms: terms)
        }
    }

    /// How much text either side of the match a snippet shows.
    public static let snippetRadius = 34

    /// Case- and accent-insensitive, because a search box that cares about either
    /// is a search box that fails on handwriting. Vision reads a hurried "é" as
    /// "e" about as often as not, and nobody types capitals into a search field.
    public static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The query split into the words that must ALL appear. Quoting isn't
    /// supported and doesn't need to be: two words is already a phrase people
    /// expect to find near each other, and requiring both is most of that.
    public static func terms(in query: String) -> [String] {
        fold(query)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Whether every term appears somewhere in the text.
    public static func matches(_ terms: [String], in text: String) -> Bool {
        guard !terms.isEmpty else { return false }
        let folded = fold(text)
        return terms.allSatisfy { folded.contains($0) }
    }

    /// Ranks the pages of one index against a query, best first.
    ///
    /// The score is how many times the terms occur, with a bonus for a page whose
    /// match sits near the top — a word in the first line of a page is usually
    /// what that page is about, and a word buried on line forty usually isn't.
    public static func search(_ query: String, in index: SearchIndex) -> [Hit] {
        search(query, in: PreparedIndex(index))
    }

    /// An index with every page's text folded, kept by a searcher that holds
    /// indexes in memory between keystrokes so each page is folded once.
    public struct PreparedIndex: Sendable {
        public let index: SearchIndex
        let folded: [String]

        public init(_ index: SearchIndex) {
            self.index = index
            self.folded = index.pages.map {
                var folded = NoteSearch.fold($0.text)
                folded.makeContiguousUTF8()
                return folded
            }
        }
    }

    /// Characters from the top of a page within which a match earns the
    /// "this is what the page is about" bonus.
    static let nearTop = 80

    public static func search(_ query: String, in prepared: PreparedIndex) -> [Hit] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }
        var hits: [Hit] = []
        for (page, folded) in zip(prepared.index.pages, prepared.folded) {
            // Byte search over text that is already folded on both sides.
            // `String.contains` compares Character by Character — grapheme
            // breaking on every step — and was measured at ~40x the cost of
            // this for the same answer, which made it nearly all of a search.
            let firsts = terms.map { byteOffset(of: $0, in: folded) }
            guard firsts.allSatisfy({ $0 != nil }) else { continue }
            var score = terms.reduce(0) { $0 + occurrences(of: $1, in: folded) }
            if let earliest = firsts.compactMap({ $0 }).min(), isNearTop(earliest, in: folded) {
                score += 2
            }
            hits.append(Hit(pageID: page.id, text: page.text, terms: terms, score: score))
        }
        return hits.sorted { $0.score > $1.score }
    }

    /// Where `needle` first occurs in `haystack` at or after byte `start`.
    static func byteOffset(of needle: String, in haystack: String, from start: Int = 0) -> Int? {
        var haystack = haystack
        var needle = needle
        return haystack.withUTF8 { hay in
            needle.withUTF8 { pin in
                guard let hayBase = hay.baseAddress, let pinBase = pin.baseAddress,
                      !pin.isEmpty, hay.count - start >= pin.count
                else { return nil }
                guard let found = memmem(hayBase + start, hay.count - start, pinBase, pin.count)
                else { return nil }
                return hayBase.distance(to: found.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    /// Whether a match at `byteOffset` is within the first `nearTop`
    /// CHARACTERS — not bytes, which would hold a page in a non-Latin script
    /// to a fraction of the distance.
    private static func isNearTop(_ byteOffset: Int, in folded: String) -> Bool {
        if byteOffset < nearTop { return true }
        guard let limit = folded.index(folded.startIndex, offsetBy: nearTop, limitedBy: folded.endIndex)
        else { return true }
        return folded.utf8.index(folded.utf8.startIndex, offsetBy: byteOffset) < limit
    }

    /// The text around the first term that appears, trimmed to one readable line.
    public static func snippet(
        of text: String, around terms: [String], radius: Int = NoteSearch.snippetRadius
    ) -> String {
        // Newlines are how a page reads, not how a result row reads.
        let flat = text
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return "" }

        // Matched INSIDE the original string, with the insensitivity as search
        // options, so the range that comes back indexes the text being shown.
        // Folding to a separate string first and re-applying the offset is what
        // slides the window off the match: folding can change a string's length
        // (a ligature becomes two characters), and then the two no longer line up.
        let found = terms
            .compactMap { flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let found else { return String(flat.prefix(radius * 2)) }

        let start = flat.distance(from: flat.startIndex, to: found.lowerBound)
        let end = flat.distance(from: flat.startIndex, to: found.upperBound)
        let lower = max(0, start - radius)
        let upper = min(flat.count, end + radius)
        guard lower < upper else { return String(flat.prefix(radius * 2)) }

        let from = flat.index(flat.startIndex, offsetBy: lower)
        let to = flat.index(flat.startIndex, offsetBy: upper)
        var snippet = String(flat[from..<to]).trimmingCharacters(in: .whitespaces)
        if lower > 0 { snippet = "…" + snippet }
        if upper < flat.count { snippet += "…" }
        return snippet
    }

    private static func occurrences(of term: String, in folded: String) -> Int {
        let length = term.utf8.count
        guard length > 0 else { return 0 }
        var count = 0
        var start = 0
        while let found = byteOffset(of: term, in: folded, from: start) {
            count += 1
            start = found + length
        }
        return count
    }
}

/// Where a hit's snippet comes from: given outright, or cut from the page's
/// text on demand.
private enum HitSnippetSource: Sendable, Equatable {
    case fixed(String)
    case page(text: String, terms: [String])
}
