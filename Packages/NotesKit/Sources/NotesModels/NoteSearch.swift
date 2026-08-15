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

    public init(version: Int = SearchIndex.currentVersion, pages: [PageText] = []) {
        self.version = version
        self.pages = pages
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
        public let snippet: String
        /// Higher is better. Ranking is by score, then by page order.
        public let score: Int

        public init(pageID: UUID, snippet: String, score: Int) {
            self.pageID = pageID
            self.snippet = snippet
            self.score = score
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
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }
        var hits: [Hit] = []
        for page in index.pages {
            let folded = fold(page.text)
            guard terms.allSatisfy({ folded.contains($0) }) else { continue }
            var score = 0
            var earliest = folded.count
            for term in terms {
                score += occurrences(of: term, in: folded)
                if let range = folded.range(of: term) {
                    earliest = min(earliest, folded.distance(from: folded.startIndex, to: range.lowerBound))
                }
            }
            if earliest < 80 { score += 2 }
            hits.append(Hit(pageID: page.id, snippet: snippet(of: page.text, around: terms), score: score))
        }
        return hits.sorted { $0.score > $1.score }
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
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchStart = folded.startIndex
        while let range = folded.range(of: term, range: searchStart..<folded.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
