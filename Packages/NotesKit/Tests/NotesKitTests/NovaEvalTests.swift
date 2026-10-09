import Foundation
import Testing
@testable import NotesModels
@testable import NotesServices

/// Scores page retrieval on the evaluation set, every run. Prints `EVAL`
/// lines; the numbers go in docs/quality/measurements.md.
@Suite("NOVA evaluation set: finding the pages that answer")
struct NovaRetrievalEvalTests {

    /// Unrelated pages, so a notebook is long enough that the page budget
    /// actually has to choose (40 extra pages of ordinary school admin).
    static func padded(_ notebook: NovaEvalSet.Notebook) -> [NovaGrounding.Page] {
        let filler = [
            "homework due friday", "bring calculator", "test next week revise", "timetable change",
            "library books return", "group project meeting", "permission slip trip", "mock exam dates",
            "reading list chapter", "presentation slides", "lab coat goggles", "uniform reminder"
        ]
        let extra = (0..<40).map { index in
            NovaGrounding.Page(
                number: 100 + index,
                text: (0..<12).map { filler[(index * 7 + $0 * 5) % filler.count] }.joined(separator: ". ")
            )
        }
        return notebook.pages + extra
    }

    struct Score {
        var asked = 0, firstRight = 0, allFound = 0, carried = 0
        var rate: (Double, Double, Double) {
            guard asked > 0 else { return (0, 0, 0) }
            return (Double(firstRight) / Double(asked), Double(allFound) / Double(asked), Double(carried) / Double(asked))
        }
    }

    private func score(padding: Bool) -> [NovaEvalSet.Style: Score] {
        var scores: [NovaEvalSet.Style: Score] = [:]
        for question in NovaEvalSet.questions where !question.answeredBy.isEmpty {
            let notebook = NovaEvalSet.notebooks[question.notebook]
            let pages = padding ? Self.padded(notebook) : notebook.pages
            let ranked = NovaGrounding.relevant(to: question.text, in: pages)
            let context = NovaGrounding.context(for: question.text, title: notebook.title, pages: pages)
            var score = scores[question.style, default: Score()]
            score.asked += 1
            if let first = ranked.first, question.answeredBy.contains(first) { score.firstRight += 1 }
            if question.answeredBy.isSubset(of: Set(ranked)) { score.allFound += 1 }
            // What reached the model: every answering page is in the context.
            if let context, question.answeredBy.isSubset(of: Set(context.included)) { score.carried += 1 }
            scores[question.style] = score
        }
        return scores
    }

    @Test("Retrieval on the evaluation set, short and padded notebooks", arguments: [false, true])
    func retrieval(padding: Bool) {
        let scores = score(padding: padding)
        var total = Score()
        for (style, score) in scores.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let (first, all, carried) = score.rate
            print("EVAL retrieval padded=\(padding) style=\(style.rawValue) n=\(score.asked) "
                + "top1=\(first.formatted(.percent)) found=\(all.formatted(.percent)) carried=\(carried.formatted(.percent))")
            total.asked += score.asked
            total.firstRight += score.firstRight
            total.allFound += score.allFound
            total.carried += score.carried
        }
        let (first, all, carried) = total.rate
        print("EVAL retrieval padded=\(padding) all n=\(total.asked) "
            + "top1=\(first.formatted(.percent)) found=\(all.formatted(.percent)) carried=\(carried.formatted(.percent))")
        // Every answering page must reach the model, however long the notebook.
        #expect(total.carried == total.asked)
        // Words in common and named pages are found first.
        let direct = (scores[.lexical]?.firstRight ?? 0) + (scores[.named]?.firstRight ?? 0)
        let directAsked = (scores[.lexical]?.asked ?? 0) + (scores[.named]?.asked ?? 0)
        #expect(Double(direct) / Double(directAsked) >= 0.9)
    }

    @Test("Every page an answer could cite is a page that exists, numbered as the app shows it")
    func citablePagesExist() {
        for notebook in NovaEvalSet.notebooks {
            let numbers = Set(notebook.pages.map(\.number))
            let reply = "From your notes (p. 2) and (pp. 4–5); see also (p. 99)."
            let source = NovaReply.source(of: reply, existing: numbers)
            if case .notes(let cited) = source {
                #expect(Set(cited).isSubset(of: numbers), "a citation to a page that doesn't exist is dropped")
            }
        }
    }
}

/// The real model on the evaluation set, through the real server, under a
/// throwaway account that is deleted afterwards. Only synthetic notes from
/// `NovaEvalSet` are sent. Off by default; run with `CLASSNOTES_LIVE_EVAL=1`.
@Suite(
    "NOVA evaluation set: the live model",
    .enabled(if: ProcessInfo.processInfo.environment["CLASSNOTES_LIVE_EVAL"] == "1"),
    .serialized
)
struct NovaLiveEvalTests {

    @Test("Cites the right page, admits what the notes don't cover, never cites a page that isn't there")
    func liveModel() async throws {
        let auth = ClassNotesAuthClient(baseURL: ClassMateAPI.baseURL())
        let email = "classnotes-eval-\(UUID().uuidString.prefix(8).lowercased())@example.invalid"
        let password = "eval-password-\(UUID().uuidString.prefix(6))"
        let session = try await auth.register(email: email, password: password, name: "NOVA Eval")
        defer {
            let token = session.token
            Task.detached {
                try? await ClassNotesAuthClient(baseURL: ClassMateAPI.baseURL())
                    .deleteAccount(password: password, token: token)
            }
        }
        let keychain = InMemorySecretStore()
        keychain.set(session.token, for: .authToken)
        let provider = NovaBackendProvider(keychain: keychain)

        var cited = 0, answerable = 0, honest = 0, outside = 0, phantom = 0, unlabelled = 0, failed = 0
        // `CLASSNOTES_EVAL_ONLY="osmosis|voltmeter"`: just the questions containing one of those.
        let only = ProcessInfo.processInfo.environment["CLASSNOTES_EVAL_ONLY"]?
            .split(separator: "|").map { $0.lowercased() } ?? []
        for question in NovaEvalSet.questions
        where only.isEmpty || only.contains(where: { question.text.lowercased().contains($0) }) {
            let notebook = NovaEvalSet.notebooks[question.notebook]
            let existing = Set(notebook.pages.map(\.number))
            guard let context = NovaGrounding.context(for: question.text, title: notebook.title, pages: notebook.pages)
            else { continue }
            let messages = [
                NovaConversation.systemPrompt,
                AIMessage(role: .system, content: context.text),
                AIMessage(role: .user, content: question.text)
            ]
            guard let answer = await ask(provider, messages) else {
                failed += 1
                print("EVAL live FAILED \(question.text)")
                continue
            }
            let shown = NovaReply.display(answer)
            let raw = Set(NovaReply.citedPages(in: shown))
            if !raw.isSubset(of: existing) { phantom += 1 }
            let source = NovaReply.source(of: shown, existing: existing)
            if question.answeredBy.isEmpty {
                outside += 1
                if source == .generalKnowledge { honest += 1 }
            } else {
                answerable += 1
                switch source {
                case .notes(let pages) where !Set(pages).isDisjoint(with: question.answeredBy): cited += 1
                case nil:
                    unlabelled += 1
                    print("EVAL live unlabelled answer: " + shown.prefix(500).replacingOccurrences(of: "\n", with: " / "))
                default: break
                }
            }
            print("EVAL live q=\"\(question.text)\" expected=\(question.answeredBy.sorted()) "
                + "source=\(String(describing: source)) cited=\(raw.sorted())")
            // The endpoint allows 20 requests a minute, and the provider has
            // its own limit behind it.
            try await Task.sleep(for: .seconds(8))
        }
        print("EVAL live answerable=\(answerable) cited-right=\(cited) unlabelled=\(unlabelled) "
            + "outside=\(outside) said-not-in-notes=\(honest) phantom-citations=\(phantom) failed=\(failed)")
        #expect(failed == 0)
        #expect(phantom == 0, "an answer cited a page the notebook doesn't have")
    }

    /// One answer, waiting out a rate limit (429) or a busy provider (503)
    /// twice before giving up.
    private func ask(_ provider: NovaBackendProvider, _ messages: [AIMessage]) async -> String? {
        for attempt in 0..<3 {
            var answer = ""
            do {
                for try await token in provider.streamReply(to: messages) { answer += token }
                return answer
            } catch AIError.badResponse(let status) where status == 429 || status == 503 {
                print("EVAL live waiting out \(status), attempt \(attempt + 1)")
                try? await Task.sleep(for: .seconds(30))
            } catch {
                return nil
            }
        }
        return nil
    }
}
