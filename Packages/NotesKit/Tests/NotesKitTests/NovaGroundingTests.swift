import ClassMateTheme
import Foundation
import StoreKit
import SwiftUI
import Synchronization
import Testing
@testable import NotesAI
@testable import NotesDesignSystem
@testable import NotesModels
@testable import NotesServices

/// A consent store of its own, so tests never share (or leave behind) a
/// permission in the real defaults.
@MainActor
func testConsent(granted: Bool = true, account: String = "test-account") -> NovaConsent {
    let defaults = UserDefaults(suiteName: "nova-consent-\(UUID().uuidString)")!
    let consent = NovaConsent(defaults: defaults) { account }
    if granted { consent.grant() }
    return consent
}

/// Records every request NOVA makes, and answers each with `reply`.
final class RecordingProvider: AIProvider {
    private let log = Mutex<[[AIMessage]]>([])
    private let reply: String

    init(reply: String = "ok") { self.reply = reply }

    var isConfigured: Bool { true }

    /// Requests for an answer (the follow-up chips' extra request left out).
    var questions: [[AIMessage]] {
        log.withLock { $0 }.filter { !($0.last?.content.hasPrefix("Suggest exactly 3") ?? false) }
    }

    func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        log.withLock { $0.append(messages) }
        let reply = reply
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}

@MainActor
private func settle(_ nova: NovaConversation) async {
    for _ in 0..<300 where nova.streaming {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Consent

/// Nothing a student writes reaches the AI provider until they have said yes
/// (App Store Review Guideline 5.1.2(i); the quality mandate's AI rule).
@MainActor
@Suite("NOVA asks before sending anything")
struct NovaConsentTests {

    @Test("Without permission the question waits and nothing is sent")
    func holdsWithoutConsent() async {
        let provider = RecordingProvider()
        let nova = NovaConversation(provider: provider, consent: testConsent(granted: false))
        nova.send("what is osmosis?")
        await settle(nova)

        #expect(nova.awaitingConsent)
        #expect(!nova.streaming)
        #expect(provider.questions.isEmpty, "a question was sent without permission")
        #expect(nova.visibleMessages.map(\.content) == ["what is osmosis?"], "the question stays on screen")
    }

    @Test("Allowing sends the held question once, and the answer is remembered")
    func allowSendsOnce() async {
        let provider = RecordingProvider(reply: "Water moving across a membrane.")
        let defaults = UserDefaults(suiteName: "nova-consent-\(UUID().uuidString)")!
        let consent = NovaConsent(defaults: defaults) { "student" }
        let nova = NovaConversation(provider: provider, consent: consent)
        nova.send("what is osmosis?")
        nova.allowAndContinue()
        await settle(nova)

        #expect(!nova.awaitingConsent)
        #expect(provider.questions.count == 1)
        #expect(nova.visibleMessages.last?.content == "Water moving across a membrane.")
        // The next conversation for the same account isn't asked again.
        #expect(NovaConsent(defaults: defaults) { "student" }.isGranted)
    }

    @Test("Declining sends nothing and hands the typed words back")
    func declineSendsNothing() async {
        let provider = RecordingProvider()
        let nova = NovaConversation(provider: provider, consent: testConsent(granted: false))
        nova.send("what is osmosis?")

        let typed = nova.declinePending()
        await settle(nova)

        #expect(typed == "what is osmosis?")
        #expect(!nova.awaitingConsent)
        #expect(nova.visibleMessages.isEmpty)
        #expect(provider.questions.isEmpty)
    }

    @Test("A snip that was declined isn't handed back as text to retype")
    func declinedSnipReturnsNothing() {
        let nova = NovaConversation(provider: RecordingProvider(), consent: testConsent(granted: false))
        nova.explainRegion(image: Data([1, 2, 3]), ocrHint: "F = ma")
        #expect(nova.declinePending() == nil)
        #expect(nova.visibleMessages.isEmpty)
    }

    @Test("Declining Read this notebook leaves the chat reading nothing")
    func declinedReadLeavesNoNotebook() {
        let nova = NovaConversation(provider: RecordingProvider(), consent: testConsent(granted: false))
        nova.explainNotebook(image: Data([1]), pageCount: 2, source: NovaNotebookSource(title: "Bio") { [] })
        #expect(nova.notebook != nil)
        nova.declinePending()
        #expect(nova.notebook == nil, "a declined read must not ground later questions")
    }

    @Test("A second request while one is held replaces it; only one ever waits")
    func oneHeldAtATime() async {
        let provider = RecordingProvider()
        let nova = NovaConversation(provider: provider, consent: testConsent(granted: false))
        nova.send("first")
        nova.send("second")
        #expect(nova.visibleMessages.map(\.content) == ["second"])
        nova.allowAndContinue()
        await settle(nova)
        #expect(provider.questions.count == 1)
        #expect(provider.questions.first?.last?.content == "second")
    }

    @Test("Permission is per account")
    func perAccount() {
        let defaults = UserDefaults(suiteName: "nova-consent-\(UUID().uuidString)")!
        var account = "alice"
        let consent = NovaConsent(defaults: defaults) { account }
        consent.grant()
        #expect(consent.isGranted)
        account = "bob"
        #expect(!consent.isGranted, "someone else signing in on the same iPad is asked for themselves")
        account = "alice"
        #expect(consent.isGranted)
    }

    @Test("Taking permission back makes the next question wait again")
    func revoke() async {
        let provider = RecordingProvider()
        let consent = testConsent()
        let nova = NovaConversation(provider: provider, consent: consent)
        consent.revoke()
        nova.send("hello")
        await settle(nova)
        #expect(nova.awaitingConsent)
        #expect(provider.questions.isEmpty)
    }
}

// MARK: - Grounding

@Suite("NOVA reads the notebook's pages, not its first few thousand characters")
struct NovaGroundingContextTests {

    private func notebook(_ count: Int, filler: String = "Lecture notes on cells and membranes.") -> [NovaGrounding.Page] {
        (1...count).map { NovaGrounding.Page(number: $0, text: "\(filler) Page body \($0).") }
    }

    @Test("An overview gives every page a share, labelled, under the budget, with the citation rule")
    func overviewCoversEveryPage() throws {
        let pages = (1...40).map {
            NovaGrounding.Page(number: $0, text: String(repeating: "topic\($0) ", count: 120))
        }
        let context = try #require(NovaGrounding.context(for: nil, title: "Biology", pages: pages))
        #expect(context.text.utf16.count <= NovaGrounding.budget)
        #expect(context.matched.isEmpty)
        #expect(context.included == Array(1...40), "the last page must not be crowded out by the first")
        #expect(context.text.contains("[Page 40]"))
        #expect(context.text.contains("topic40"))
        #expect(context.text.contains(NovaGrounding.citationRule))
    }

    @Test("The page that answers the question is quoted first and in full")
    func questionFindsItsPage() throws {
        var pages = notebook(10)
        pages[6].text = "The Krebs cycle runs in the mitochondrial matrix and yields NADH."
        let context = try #require(NovaGrounding.context(for: "Where does the Krebs cycle happen?", title: "Bio", pages: pages))
        #expect(context.matched.first == 7)
        #expect(context.text.contains("mitochondrial matrix and yields NADH"))
    }

    @Test("A word on most pages says nothing about which page is meant")
    func commonWordsDoNotMatch() {
        let pages = notebook(10)
        #expect(NovaGrounding.relevant(to: "tell me about membranes", in: pages).isEmpty)
    }

    @Test("Pages the question names come first", arguments: [
        ("summarise page 3", [3]),
        ("compare pages 2 and 5", [2, 5]),
        ("what's on pp. 2-4?", [2, 3, 4]),
        ("p. 6, 8", [6, 8]),
        ("pages 9 to 7", [9, 7])
    ])
    func namedPages(question: String, expected: [Int]) {
        #expect(NovaGrounding.relevant(to: question, in: notebook(10)) == expected)
    }

    @Test("A page named that doesn't exist is ignored")
    func namedMissingPage() {
        #expect(NovaGrounding.relevant(to: "what's on page 40?", in: notebook(10)).isEmpty)
    }

    @Test("The budget holds for text that isn't ASCII (emoji, CJK, accents)")
    func budgetCountsUTF16() throws {
        let pages = (1...12).map {
            NovaGrounding.Page(number: $0, text: String(repeating: "細胞膜 🧬 é ", count: 400))
        }
        let context = try #require(NovaGrounding.context(for: "細胞膜", title: "生物 🧬", pages: pages))
        #expect(context.text.utf16.count <= NovaGrounding.budget)
    }

    @Test("A long page is cut around the match, not from the top")
    func excerptFollowsTheMatch() throws {
        var pages = notebook(6)
        pages[2].text = String(repeating: "Unrelated filler sentence. ", count: 600) + "Osmosis is water crossing a membrane."
        let context = try #require(NovaGrounding.context(for: "explain osmosis", title: "Bio", pages: pages))
        #expect(context.matched.first == 3)
        #expect(context.text.contains("Osmosis is water crossing a membrane."))
    }

    @Test("A notebook with nothing readable sends nothing")
    func emptyNotebook() {
        let pages = [NovaGrounding.Page(number: 1, text: "  \n "), NovaGrounding.Page(number: 2, text: "")]
        #expect(NovaGrounding.context(for: "anything", title: "Empty", pages: pages) == nil)
    }

    @Test("The cover is labelled as the cover")
    func coverLabel() throws {
        let pages = [NovaGrounding.Page(number: 0, text: "Biology 101"), NovaGrounding.Page(number: 1, text: "Cells")]
        let context = try #require(NovaGrounding.context(for: nil, title: "Bio", pages: pages))
        #expect(context.text.contains("[Cover]\nBiology 101"))
        #expect(context.text.contains("[Page 1]\nCells"))
    }
}

// MARK: - Conversation

@MainActor
@Suite("A grounded chat")
struct NovaGroundedConversationTests {

    private func source() -> NovaNotebookSource {
        NovaNotebookSource(title: "Biology") {
            [
                NovaGrounding.Page(number: 1, text: "Mitosis makes two identical cells."),
                NovaGrounding.Page(number: 2, text: "Meiosis makes four gametes."),
                NovaGrounding.Page(number: 3, text: "The Krebs cycle yields NADH.")
            ]
        }
    }

    @Test("Each question carries its pages as context, kept out of the transcript")
    func questionCarriesPages() async throws {
        let provider = RecordingProvider(reply: "It yields NADH (p. 3).")
        let nova = NovaConversation(provider: provider, consent: testConsent())
        nova.explainNotebook(image: Data([1]), pageCount: 3, source: source())
        await settle(nova)
        nova.send("what does the Krebs cycle make?")
        await settle(nova)

        let request = try #require(provider.questions.last)
        let context = try #require(request.dropLast().last)
        #expect(context.role == .system)
        #expect(context.content.contains("[Page 3]\nThe Krebs cycle yields NADH."))
        #expect(request.last?.content == "what does the Krebs cycle make?")
        #expect(!nova.visibleMessages.contains { $0.content.contains("[Page 3]") })

        let question = try #require(nova.visibleMessages.last { $0.role == .user })
        #expect(nova.grounding[question.id]?.matched.first == 3)
        let reply = try #require(nova.visibleMessages.last)
        #expect(nova.source(ofReply: reply.id) == .notes(pages: [3]))
    }

    @Test("The page context reaches the server; NOVA's own instructions don't pose as the page")
    func payloadCarriesPagesNotIdentity() async throws {
        let provider = RecordingProvider()
        let nova = NovaConversation(provider: provider, consent: testConsent())
        nova.explainNotebook(image: Data([1]), pageCount: 3, source: source())
        await settle(nova)
        let payload = NovaBackendProvider.payload(for: try #require(provider.questions.first))
        let context = try #require(payload["pageContext"] as? String)
        #expect(context.contains("Meiosis makes four gametes."))
        #expect(!context.contains("You are NOVA"))
    }

    @Test("After Stop, questions carry no notes")
    func stopReading() async throws {
        let provider = RecordingProvider()
        let nova = NovaConversation(provider: provider, consent: testConsent())
        nova.explainNotebook(image: Data([1]), pageCount: 3, source: source())
        await settle(nova)
        nova.stopReadingNotebook()
        nova.send("unrelated question")
        await settle(nova)
        let request = try #require(provider.questions.last)
        #expect(!request.contains { $0.role == .system && $0.content.contains("[Page") })
    }

    @Test("A new chat starts reading nothing")
    func resetDropsNotebook() async {
        let nova = NovaConversation(provider: RecordingProvider(), consent: testConsent())
        nova.explainNotebook(image: Data([1]), pageCount: 3, source: source())
        await settle(nova)
        nova.reset()
        #expect(nova.notebook == nil)
        #expect(nova.grounding.isEmpty)
    }

    @Test("A question that carried no notes earns no label")
    func ungroundedReplyHasNoSource() async throws {
        let nova = NovaConversation(provider: RecordingProvider(reply: "Yes (p. 2)."), consent: testConsent())
        nova.send("hi")
        await settle(nova)
        let reply = try #require(nova.visibleMessages.last)
        #expect(nova.source(ofReply: reply.id) == nil)
    }
}

// MARK: - Labels and payload

@Suite("Where an answer came from")
struct NovaReplySourceTests {

    @Test("Citations are read, deduplicated and checked against real pages")
    func citations() {
        let existing: Set = [1, 2, 3, 4, 5]
        #expect(NovaReply.source(of: "Mitosis (p. 2) and meiosis (pp. 3–4).", existing: existing)
                == .notes(pages: [2, 3, 4]))
        #expect(NovaReply.source(of: "See (page 5) and again (p. 5).", existing: existing) == .notes(pages: [5]))
        #expect(NovaReply.source(of: "As noted (p. 99).", existing: existing) == nil, "a page that isn't there")
        #expect(NovaReply.source(of: "No citation here.", existing: existing) == nil)
    }

    @Test("General knowledge is recognised under Markdown and emoji")
    func generalKnowledge() {
        #expect(NovaReply.source(of: "**Not in your notes:** the sun is a star.", existing: [1]) == .generalKnowledge)
        #expect(NovaReply.source(of: "💡 Not in your notes: water boils at 100 °C.", existing: [1]) == .generalKnowledge)
    }

    @Test("Page lists read naturally")
    func pageList() {
        #expect(NovaPageList.describe([3]) == "page 3")
        #expect(NovaPageList.describe([2, 5]) == "pages 2 and 5")
        #expect(NovaPageList.describe([1, 4, 6]) == "pages 1, 4 and 6")
        #expect(NovaPageList.describe([0]) == "the cover")
        #expect(NovaPageList.describe([0, 3]) == "the cover and page 3")
    }
}

@MainActor
@Suite("What reaches the NOVA endpoint")
struct NovaPayloadLimitTests {

    @Test("NOVA's identity prompt is never sent as the student's page")
    func identityIsNotPageContext() {
        let payload = NovaBackendProvider.payload(for: [NovaConversation.systemPrompt, AIMessage(role: .user, content: "hi")])
        #expect(payload["pageContext"] == nil)
    }

    @Test("A question over the endpoint's limit is cut to fit instead of being refused")
    func longQuestionIsClipped() throws {
        let long = String(repeating: "🧬", count: 4_000) // 8,000 UTF-16 units
        let payload = NovaBackendProvider.payload(for: [AIMessage(role: .user, content: long)])
        let text = try #require(payload["text"] as? String)
        #expect(text.utf16.count <= NovaBackendProvider.maximumFieldLength)
        #expect(!text.isEmpty)
    }
}

@Suite("Page numbers as the app shows them")
struct PageNumberingTests {

    @Test("The cover is 0 and page 1 is the first page after it")
    func numbering() {
        var cover = PageRecord(template: .ruled)
        cover.isCover = true
        let pages = [cover, PageRecord(template: .ruled), PageRecord(template: .ruled)]
        #expect(PageNumbering.numbers(of: pages) == [0, 1, 2])
        #expect(PageNumbering.page(numbered: 2, in: pages)?.id == pages[2].id)
        #expect(PageNumbering.page(numbered: 0, in: pages)?.id == cover.id)
        #expect(PageNumbering.page(numbered: 3, in: pages) == nil)
    }

    @Test("Without a cover, numbering starts at the first page")
    func noCover() {
        let pages = [PageRecord(template: .ruled), PageRecord(template: .ruled)]
        #expect(PageNumbering.numbers(of: pages) == [1, 2])
        #expect(PageNumbering.page(numbered: 0, in: pages) == nil)
    }
}

// MARK: - Plain words for VoiceOver and errors

@Suite("What the user hears and reads")
struct PlainLanguageTests {

    @Test("Every shelf icon has a spoken name, not a symbol name")
    func shelfIconsAreNamed() {
        for symbol in ShelfSymbol.allCases {
            #expect(!symbol.spokenName.isEmpty)
            #expect(!symbol.spokenName.contains("."), "\(symbol.systemName) reads as a symbol name")
        }
        #expect(Set(ShelfSymbol.allCases.map(\.spokenName)).count == ShelfSymbol.allCases.count)
    }

    @Test("Restore Purchases: cancelling isn't an error, and failures read as words")
    func restoreMessages() {
        #expect(EntitlementService.restoreMessage(for: StoreKitError.userCancelled) == nil)
        let offline = EntitlementService.restoreMessage(for: StoreKitError.networkError(URLError(.notConnectedToInternet)))
        #expect(offline?.contains("App Store") == true)
        let other = EntitlementService.restoreMessage(for: StoreKitError.unknown)
        #expect(other?.contains("StoreKit") == false)
    }
}

// MARK: - Rendering

@MainActor
@Suite("NOVA's consent and source views render under every theme")
struct NovaGroundingRenderTests {

    @Test(arguments: ThemePreset.allCases)
    func renders(preset: ThemePreset) throws {
        let conversation = NovaConversation(provider: RecordingProvider(), consent: testConsent(granted: false))
        let view = VStack(alignment: .leading, spacing: 14) {
            NovaNotebookChip {}
            NovaGroundingCaption(context: NovaGrounding.Context(text: "", matched: [3, 7], included: [1, 3, 7]))
            NovaSourceBadge(source: .notes(pages: [2, 5]), onOpenPage: { _ in })
            NovaSourceBadge(source: .generalKnowledge)
            NovaConsentCard(conversation: conversation, draft: .constant(""))
        }
        .padding(16)
        .frame(width: 372)
        .background(preset.spec.surface.color)
        .environment(\.theme, preset.spec)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.uiImage, "\(preset.rawValue) failed to render")
        #expect(image.size.height > 300)
        // Pictures to look at by eye, only when asked for:
        // TEST_RUNNER_NOVA_RENDER_DIR=<folder> xcodebuild test …
        if let folder = ProcessInfo.processInfo.environment["NOVA_RENDER_DIR"], let png = image.pngData() {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("nova-grounding-\(preset.rawValue).png")
            try png.write(to: url)
        }
    }
}
