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

    /// Page numbers cited in brackets, in the order first cited.
    static func citedPages(in answer: String) -> [Int] {
        let pattern = #"\((?:pp?|pg|pages?)\.?\s*([0-9][0-9\s,–\-&and]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(answer.startIndex..., in: answer)
        var pages: [Int] = []
        for match in regex.matches(in: answer, range: range) {
            guard let list = Range(match.range(at: 1), in: answer) else { continue }
            pages += NovaGrounding.pageReferences(in: "pages " + answer[list])
        }
        var seen = Set<Int>()
        return pages.filter { seen.insert($0).inserted }
    }
}
