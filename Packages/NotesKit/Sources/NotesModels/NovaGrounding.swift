import Foundation

/// What NOVA is shown of a notebook, and how. Pure, so exactly what leaves the
/// device is pinned by tests.
///
/// A notebook goes to NOVA only after the user asks for it ("Read this
/// notebook"). From then on each question carries the pages that answer it
/// best, plus a fair share of every other page, instead of the notebook's first
/// few thousand characters. The server keeps a request's page context to 6,000
/// characters and each older turn to 2,000, so a notebook read once in the first
/// turn is gone by the third question; that is why the pages travel with every
/// question rather than once.
public enum NovaGrounding {

    /// One page, numbered the way the app shows it: the cover is `0`
    /// ("Cover"), and the first page after it is page 1.
    public struct Page: Sendable, Equatable {
        public var number: Int
        public var text: String

        public init(number: Int, text: String) {
            self.number = number
            self.text = text
        }

        var label: String { number == 0 ? "Cover" : "Page \(number)" }
    }

    /// What one question carries.
    public struct Context: Sendable, Equatable {
        /// The page context sent with the question.
        public var text: String
        /// Pages quoted because they match the question, best first. Empty when
        /// the question matched nothing in particular (or there was no
        /// question), in which case every page was given an even share.
        public var matched: [Int]
        /// Every page that appears in `text`, in page order.
        public var included: [Int]
    }

    /// The page-context budget, in UTF-16 code units, because that is how the
    /// server's JavaScript validator measures length. Under its 6,000 limit
    /// with room to spare.
    public static let budget = 5_600
    /// The most pages a question quotes in detail.
    public static let maximumMatches = 4

    /// The instruction that asks NOVA to say where an answer came from. The
    /// app reads the answer back for exactly these two markers
    /// (`NovaReply.source`), so keep them in step.
    public static let citationRule = """
        When these pages answer the question, answer from them and cite the page \
        in brackets, like (p. 2). If they don't, begin your answer with \
        "Not in your notes:" and answer from general knowledge.
        """

    /// The page context for `question` (nil: an overview of the whole
    /// notebook), or nil when the notebook has no readable text at all.
    public static func context(
        for question: String?, title: String, pages: [Page], budget: Int = budget
    ) -> Context? {
        let readable = pages
            .map { Page(number: $0.number, text: tidy($0.text)) }
            .filter { !$0.text.isEmpty }
        guard !readable.isEmpty else { return nil }

        let header = "Pages from the student's own notebook \"\(clip(title, to: 80))\", "
            + "numbered as the app shows them."
        let fixed = header.utf16.count + citationRule.utf16.count + 4
        var available = max(0, budget - fixed)

        let matches = question.map { relevant(to: $0, in: readable) } ?? []
        let terms = question.map(searchTerms(in:)) ?? []
        var quoted: [Int: String] = [:]

        // Matched pages first, best first, each up to an even split of most of
        // the budget. Short matches hand what they didn't use to the rest.
        if !matches.isEmpty {
            let others = readable.count - matches.count
            var share = others > 0 ? available * 7 / 10 : available
            for (offset, number) in matches.enumerated() {
                guard let page = readable.first(where: { $0.number == number }) else { continue }
                let limit = share / (matches.count - offset) - blockOverhead(page)
                guard limit > 0 else { break }
                let excerpt = self.excerpt(of: page.text, around: terms, limit: limit)
                quoted[number] = excerpt
                let used = excerpt.utf16.count + blockOverhead(page)
                share -= used
                available -= used
            }
        }

        // Every other page gets an even share of what's left, so NOVA still
        // knows what the rest of the notebook is about.
        let rest = readable.filter { quoted[$0.number] == nil }
        for (number, text) in evenShares(of: rest, budget: available) {
            quoted[number] = text
        }

        let included = readable.map(\.number).filter { quoted[$0] != nil }
        let blocks = included.compactMap { number -> String? in
            guard let page = readable.first(where: { $0.number == number }),
                  let text = quoted[number] else { return nil }
            return "[\(page.label)]\n\(text)"
        }
        // The rule goes last and is never the part cut: without it the answer
        // can't be labelled.
        let rule = "\n\n" + citationRule
        let body = clip(([header] + blocks).joined(separator: "\n\n"), to: budget - rule.utf16.count)
        return Context(text: body + rule, matched: matches, included: included)
    }

    // MARK: - Relevance

    /// Pages that answer `question`, best first: pages it names ("page 3",
    /// "pp. 2-4"), then pages ranked by the words they share with it.
    ///
    /// A word that appears on most pages says nothing about which page is
    /// meant, so only words on at most half the pages count (any word counts in
    /// a one- or two-page notebook). Rarer words weigh more.
    public static func relevant(to question: String, in pages: [Page]) -> [Int] {
        let numbers = Set(pages.map(\.number))
        var ranked = pageReferences(in: question).filter { numbers.contains($0) }

        let terms = searchTerms(in: question)
        if !terms.isEmpty {
            let folded = pages.map { (number: $0.number, words: words(in: $0.text)) }
            let count = folded.count
            let ceiling = count <= 2 ? count : max(1, count / 2)
            var weights: [String: Double] = [:]
            for term in Set(terms) {
                let frequency = folded.filter { $0.words[term] != nil }.count
                guard frequency > 0, frequency <= ceiling else { continue }
                weights[term] = log(1 + Double(count) / Double(frequency))
            }
            let scored = folded.compactMap { page -> (number: Int, score: Double)? in
                let score = weights.reduce(0.0) { total, entry in
                    guard let hits = page.words[entry.key] else { return total }
                    return total + entry.value * (1 + log(Double(hits)))
                }
                return score > 0 ? (page.number, score) : nil
            }
            let byScore = scored
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.number < $1.number }
                .map(\.number)
            for number in byScore where !ranked.contains(number) {
                ranked.append(number)
            }
        }
        return Array(ranked.prefix(maximumMatches))
    }

    /// Page numbers the question names: "page 3", "pages 2 and 5", "p. 4",
    /// "pp. 2-4". A range is capped at ten pages.
    public static func pageReferences(in question: String) -> [Int] {
        let tokens = NoteSearch.fold(question)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "-", with: " - ")
            .replacingOccurrences(of: ",", with: " , ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let openers: Set = ["page", "pages", "p.", "pp.", "pg", "pg.", "p", "pp"]
        let joiners: Set = [",", "and", "&", "-", "to"]
        var found: [Int] = []
        var index = 0
        while index < tokens.count {
            guard openers.contains(tokens[index]) else {
                index += 1
                continue
            }
            index += 1
            var previous: Int?
            var pendingRange = false
            while index < tokens.count {
                let token = tokens[index].trimmingCharacters(in: .punctuationCharacters)
                if let number = Int(token), number > 0 {
                    if pendingRange, let start = previous, number > start {
                        for page in (start + 1)...min(number, start + 10) { found.append(page) }
                    } else {
                        found.append(number)
                    }
                    previous = number
                    pendingRange = false
                } else if joiners.contains(tokens[index]) {
                    pendingRange = tokens[index] == "-" || tokens[index] == "to"
                } else {
                    break
                }
                index += 1
            }
        }
        var seen = Set<Int>()
        return found.filter { seen.insert($0).inserted }
    }

    /// The question's content words: folded, split on anything that isn't a
    /// letter or digit, at least three characters, common English words
    /// dropped.
    static func searchTerms(in question: String) -> [String] {
        words(in: question).keys
            .filter { $0.count >= 3 && !stopWords.contains($0) && Int($0) == nil }
            .sorted()
    }

    private static func words(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in NoteSearch.fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            counts[String(word), default: 0] += 1
        }
        return counts
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had",
        "her", "was", "one", "our", "out", "has", "him", "his", "how", "its", "may",
        "new", "now", "old", "see", "two", "who", "did", "get", "let", "say", "she",
        "too", "use", "what", "when", "where", "which", "why", "with", "this", "that",
        "these", "those", "there", "their", "them", "then", "than", "from", "have",
        "does", "about", "into", "your", "mine", "page", "pages", "note", "notes",
        "notebook", "explain", "tell", "give", "show", "write", "wrote", "mean",
        "means", "summarise", "summarize", "summary", "please", "could", "would",
        "should", "will", "just", "like", "also", "some", "more", "most", "other"
    ]

    // MARK: - Cutting text to fit

    /// Up to `limit` UTF-16 units of `text`, cut around the first of `terms`
    /// it contains (or from the start). The match is found in the ORIGINAL
    /// string, with case and accents ignored, because folding a copy and
    /// re-applying the offset slides the window when folding changes the
    /// string's length.
    static func excerpt(of text: String, around terms: [String], limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.utf16.count > limit else { return text }
        let anchor = terms
            .compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .map(\.lowerBound)
            .min()
        guard let anchor else { return clip(text, to: limit) }
        // A third of the window before the match, the rest after it.
        var start = anchor
        var before = 0
        while start > text.startIndex, before < limit / 3 {
            start = text.index(before: start)
            before += text[start].utf16.count
        }
        let lead = start > text.startIndex ? "…" : ""
        return lead + clip(String(text[start...]), to: limit - lead.utf16.count)
    }

    /// Splits `budget` evenly across `pages`; a page shorter than its share
    /// gives the remainder to the pages after it.
    static func evenShares(of pages: [Page], budget: Int) -> [(Int, String)] {
        var remaining = budget
        var result: [(Int, String)] = []
        let order = pages.indices.sorted {
            (pages[$0].text.utf16.count, $0) < (pages[$1].text.utf16.count, $1)
        }
        for (position, index) in order.enumerated() {
            let page = pages[index]
            let share = remaining / (order.count - position) - blockOverhead(page)
            guard share >= minimumShare else { continue }
            let text = clip(page.text, to: share)
            result.append((page.number, text))
            remaining -= text.utf16.count + blockOverhead(page)
        }
        return result
    }

    /// Below this, a page's share would be a fragment that says nothing.
    static let minimumShare = 40

    /// "[label]\n" before the page's text, and the blank line between blocks.
    private static func blockOverhead(_ page: Page) -> Int { page.label.utf16.count + 5 }

    /// `text` cut to at most `limit` UTF-16 units on a character boundary,
    /// with an ellipsis when it was cut.
    public static func clip(_ text: String, to limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        guard limit > 1 else { return "" }
        var used = 0
        var end = text.startIndex
        for character in text {
            let size = character.utf16.count
            guard used + size <= limit - 1 else { break }
            used += size
            end = text.index(after: end)
        }
        return String(text[..<end]) + "…"
    }

    private static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
