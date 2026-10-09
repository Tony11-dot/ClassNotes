import Foundation
import NotesModels

extension NovaReply {

    /// Where a grounded answer says it came from.
    public enum Source: Sendable, Equatable {
        /// It cites these pages of the notebook (only pages that exist).
        case notes(pages: [Int])
        /// It says the notebook doesn't cover the question.
        case generalKnowledge
    }

    /// Reads an answer for the two markers `NovaGrounding.citationRule` asks
    /// for: page citations like "(p. 2)" or "(pp. 3–4)", or an opening
    /// "Not in your notes:". Nil when it has neither, because a label the
    /// answer didn't earn is worse than no label.
    ///
    /// Only pages in `existing` count: a model can cite a page that isn't
    /// there, and a link to nothing is a broken promise.
    public static func source(of answer: String, existing: Set<Int>) -> Source? {
        let opening = answer.drop { !$0.isLetter }.prefix(40).lowercased()
        if opening.hasPrefix("not in your notes") { return .generalKnowledge }
        let cited = citedPages(in: answer).filter(existing.contains)
        return cited.isEmpty ? nil : .notes(pages: cited)
    }

    /// Page numbers cited, in the order first cited.
    ///
    /// Read as the model actually writes them, which the live evaluation
    /// (`NovaLiveEvalTests`) showed is not only "(p. 2)": it also writes
    /// "【p. 1】" and "【Page 3】" (its own citation brackets), "[p. 4]",
    /// "(see p. 3)", and, asked to go through a page, a heading "### Page 1"
    /// or a bold "**Page 1 – …**" line.
    /// Reading only the first form left one answer in five that DID cite its
    /// page unlabelled.
    static func citedPages(in answer: String) -> [Int] {
        var pages: [Int] = []
        let range = NSRange(answer.startIndex..., in: answer)
        for regex in [bracketed, heading] {
            for match in regex.matches(in: answer, range: range) {
                guard let list = Range(match.range(at: 1), in: answer) else { continue }
                pages += NovaGrounding.pageReferences(in: "pages " + answer[list])
            }
        }
        var seen = Set<Int>()
        return pages.filter { seen.insert($0).inserted }
    }

    // swiftlint:disable force_try
    /// "(p. 2)", "[pp. 3–4]", "【Page 3】", "(see p. 3)", "(from pages 2 and 5)".
    private static let bracketed = try! NSRegularExpression(
        pattern: #"[(\[【〔]\s*(?:(?:see|from|on|cf\.?)\s+)?(?:pp?|pg|pages?)\.?\s*([0-9][0-9\s,–\-&and]*)[)\]】〕]"#,
        options: [.caseInsensitive]
    )
    /// A Markdown heading, or a bold opening line, that names the page it
    /// covers: "### Page 1 – …", "**Page 1 – …**".
    private static let heading = try! NSRegularExpression(
        pattern: #"(?m)^\s{0,3}(?:#{1,6}\s*|\*\*\s*)(?:pp?\.|pages?)\s*([0-9][0-9\s,–\-&and]*?)(?=\s*(?::|\s[–—-]|$))"#,
        options: [.caseInsensitive]
    )
    // swiftlint:enable force_try
}
