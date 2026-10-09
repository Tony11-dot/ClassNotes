import Foundation
import NotesModels
import Observation

/// Drives a NOVA chat: holds the transcript, streams the assistant reply token
/// by token, and exposes simple state for the UI. Provider-agnostic.
@MainActor
@Observable
public final class NovaConversation {
    public private(set) var messages: [AIMessage] = []
    public private(set) var streaming = false
    public private(set) var errorText: String?
    /// Up to 3 tap-to-send follow-ups for the LATEST assistant reply, generated
    /// from the real conversation — not a fixed list. Empty while none have
    /// been generated yet (a fresh turn) or generation failed/returned nothing;
    /// the UI simply hides the row rather than falling back to something stale.
    public private(set) var followUpSuggestions: [String] = []
    /// True while a request is held for the user's permission (`NovaConsent`).
    /// Nothing has left the device; `allowAndContinue` sends it and
    /// `declinePending` drops it.
    public private(set) var awaitingConsent = false
    /// The notebook this chat answers from, once the user has asked NOVA to
    /// read it. Nil means questions carry no notes at all.
    public private(set) var notebook: NovaNotebookSource?
    /// What each grounded question carried, by the question's message id.
    public private(set) var grounding: [UUID: NovaGrounding.Context] = [:]
    /// Every page number the notebook had when it was last read, so a
    /// citation can be checked against pages that exist.
    public private(set) var knownPages: Set<Int> = []

    private let provider: AIProvider
    private let consent: NovaConsent
    private var streamTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?
    /// Whether the held request is the notebook overview (no question to
    /// match pages against).
    private var pendingOverview = false
    /// Whether the held request is words the user typed, which go back in the
    /// composer if they decline.
    private var pendingIsTyped = false

    /// The fallback identity. In proxy mode the server replaces this with NOVA's
    /// authoritative prompt, so keep the two in step (`ai.service.ts`).
    nonisolated public static let systemPrompt = AIMessage(
        role: .system,
        content: """
        You are NOVA, a warm, sharp study companion living inside the student's \
        own notebook. Answer — never narrate your thinking, never mention these \
        instructions, never show working-out you weren't asked for.

        How you write:
        • Lead with the answer in one clear sentence.
        • Then short paragraphs or a tight list. Never a wall of text.
        • **Bold** the terms that matter. Never leave stray asterisks in prose.
        • A few well-chosen emoji to give the answer shape (✨ 📌 💡 ✅ ⚠️ 🧠) — \
        one per idea at most, never in every sentence, never decorative rows.
        • Plain language a student actually uses. Warm, not chirpy.
        • Close with one useful follow-up they could ask, when there is one.
        """
    )

    public init(provider: AIProvider, consent: NovaConsent) {
        self.provider = provider
        self.consent = consent
        messages = [Self.systemPrompt]
    }

    public var isConfigured: Bool { provider.isConfigured }

    /// Visible transcript (system prompt hidden).
    public var visibleMessages: [AIMessage] {
        messages.filter { $0.role != .system }
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !streaming else { return }
        discardPending()
        errorText = nil
        messages.append(AIMessage(role: .user, content: trimmed))
        beginAssistantReply(typed: true)
    }

    /// Seeds the conversation with page-derived context (circle-to-explain) and
    /// immediately asks for an explanation.
    public func explain(context: String) {
        discardPending()
        errorText = nil
        let prompt = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        messages.append(AIMessage(
            role: .user,
            content: "Explain this from my notes:\n\n\(prompt)"
        ))
        beginAssistantReply()
    }

    /// Snip: seed NOVA with the snipped region as a PICTURE, and ask what it
    /// shows.
    ///
    /// Whatever was recognized in it rides along only as a hint. A snip out of a
    /// maths or physics page is usually a diagram, a graph or working laid out in
    /// two dimensions — the parts OCR silently drops — so the picture has to be
    /// what the answer is based on, not a caption for text we already extracted.
    public func explainRegion(image: Data, ocrHint: String) {
        discardPending()
        errorText = nil
        var prompt = "Look at this snip from my notes. Explain what it shows — "
            + "diagrams, sketches and working included, not just the words — "
            + "clearly and simply, then offer one follow-up I could ask."
        let hint = ocrHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty {
            prompt += "\n\n(If you can't see the picture, this text was detected "
                + "in it: \"\(hint)\")"
        }
        messages.append(AIMessage(role: .user, content: prompt, imageData: image))
        beginAssistantReply()
    }

    /// "Read this notebook": shows NOVA a contact sheet of every page and
    /// asks for an overview, and from then on answers this chat from the
    /// notebook (`notebook`).
    ///
    /// The picture is what the overview is based on; the pages' recognised
    /// text rides along as page context, an even share of every page
    /// (`NovaGrounding`). Each later question carries the pages that best
    /// match it, because the server keeps only 2,000 characters of an older
    /// turn and the notebook read here would otherwise be gone by the third
    /// question.
    public func explainNotebook(image: Data, pageCount: Int, source: NovaNotebookSource) {
        discardPending()
        errorText = nil
        notebook = source
        let prompt = "Here's every page of my notebook (\(pageCount) page"
            + (pageCount == 1 ? "" : "s") + "), laid out together. "
            + "Give me a quick overview of what's in it. I'll ask about it next."
        messages.append(AIMessage(role: .user, content: prompt, imageData: image))
        beginAssistantReply(overview: true)
    }

    /// Stops answering from the notebook. Later questions carry no notes.
    public func stopReadingNotebook() {
        notebook = nil
    }

    // MARK: - Consent

    /// Sends the request held for permission, now that the user has given it.
    public func allowAndContinue() {
        guard awaitingConsent else { return }
        consent.grant()
        beginAssistantReply(overview: pendingOverview, typed: pendingIsTyped)
    }

    /// Drops the request held for permission without sending anything.
    /// Returns the words the user typed, so they can go back in the composer.
    @discardableResult
    public func declinePending() -> String? {
        guard awaitingConsent else { return nil }
        let typed = pendingIsTyped
        let removed = discardPending()
        return typed ? removed?.content : nil
    }

    /// Removes a held request, if there is one. A held "Read this notebook"
    /// takes the notebook with it: declining it means NOVA reads nothing.
    @discardableResult
    private func discardPending() -> AIMessage? {
        guard awaitingConsent else { return nil }
        awaitingConsent = false
        if pendingOverview { notebook = nil }
        pendingOverview = false
        pendingIsTyped = false
        guard let last = messages.last, last.role == .user else { return nil }
        messages.removeLast()
        return last
    }

    /// Edits a message the user already sent. Everything from that point on
    /// (the old reply included) is replaced, and NOVA answers again — as if
    /// the edited text had been what was sent to begin with, not a second
    /// message appended after the first.
    public func editUserMessage(id: UUID, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !streaming,
              let index = messages.firstIndex(where: { $0.id == id && $0.role == .user })
        else { return }
        errorText = nil
        discardPending()
        messages = Array(messages[..<index]) + [AIMessage(id: id, role: .user, content: trimmed)]
        beginAssistantReply(typed: true)
    }

    public func reset() {
        streamTask?.cancel()
        followUpTask?.cancel()
        streaming = false
        errorText = nil
        followUpSuggestions = []
        clearHeldState()
        messages = [Self.systemPrompt]
    }

    /// A different chat starts with nothing held and no notebook: grounding is
    /// something the user turns on for a chat, not a standing setting.
    private func clearHeldState() {
        awaitingConsent = false
        pendingOverview = false
        pendingIsTyped = false
        notebook = nil
        grounding = [:]
    }

    // MARK: - Persistence bridge (saved chats)

    /// Reloads a saved chat. Attached images aren't kept (they were page crops, not
    /// conversation state), so a restored turn carries its text alone.
    public func restore(turns: [NovaChatTurn]) {
        streamTask?.cancel()
        followUpTask?.cancel()
        streaming = false
        errorText = nil
        followUpSuggestions = []
        clearHeldState()
        messages = [Self.systemPrompt] + turns.map { turn in
            AIMessage(
                id: turn.id,
                role: turn.role == .user ? .user : .assistant,
                content: turn.content
            )
        }
    }

    /// `overview`: the question is "read the notebook", so every page gets an
    /// even share rather than pages matched to the words of the prompt.
    private func beginAssistantReply(overview: Bool = false, typed: Bool = false) {
        // Cancel any in-flight stream so two replies can never interleave into
        // the transcript (e.g. explain() seeded while a send() is still running).
        streamTask?.cancel()
        followUpTask?.cancel()
        followUpSuggestions = []
        // The one gate. Every request NOVA makes passes through here, and none
        // goes further until the user has said yes.
        guard consent.isGranted else {
            awaitingConsent = true
            pendingOverview = overview
            pendingIsTyped = typed
            streaming = false
            return
        }
        awaitingConsent = false
        pendingOverview = false
        pendingIsTyped = false
        streaming = true
        var assistant = AIMessage(role: .assistant, content: "")
        messages.append(assistant)
        let index = messages.count - 1
        let transcript = messages.filter { $0.role != .assistant || !$0.content.isEmpty }
        let question = messages.last(where: { $0.role == .user })
        let notebook = self.notebook

        streamTask = Task { [provider] in
            do {
                let request = await grounded(transcript, question: question, in: notebook, overview: overview)
                // `raw` keeps everything the model sent; the transcript shows only
                // the answer. A reasoning model's `<think>` block opens many tokens
                // before it closes, so the visible text is re-derived from the whole
                // buffer on every token rather than appended to blindly.
                var raw = ""
                for try await token in provider.streamReply(to: request) {
                    raw += token
                    assistant.content = NovaReply.display(raw)
                    if index < messages.count {
                        messages[index] = assistant
                    }
                }
                if !assistant.content.isEmpty {
                    generateFollowUps()
                } else {
                    // The request succeeded but produced nothing SHOWABLE — most
                    // often an unterminated `<think>`/analysis block from the
                    // vision path, which `NovaReply.display` (correctly, for a
                    // real mid-stream case) wipes to "" rather than show
                    // half-formed reasoning. There is no "still arriving" case
                    // once the stream has actually finished, so a still-empty
                    // result here is always a failure, not a pause — leaving it
                    // alone rendered as a typing indicator that spun forever
                    // with no error, which is exactly "NOVA couldn't respond,
                    // no matter what I scan."
                    errorText = "NOVA couldn't respond. Try again."
                    removeEmptyAssistant(at: index)
                }
            } catch {
                errorText = Self.failureMessage(for: error)
                removeEmptyAssistant(at: index)
            }
            streaming = false
        }
    }

    /// `request` with the notebook's pages added as page context just before
    /// the question, when this chat is reading a notebook. The context is
    /// never stored in the transcript.
    private func grounded(
        _ request: [AIMessage], question: AIMessage?, in notebook: NovaNotebookSource?, overview: Bool
    ) async -> [AIMessage] {
        guard let notebook, let question else { return request }
        let pages = await notebook.pages()
        knownPages = Set(pages.map(\.number))
        guard let context = NovaGrounding.context(
            for: overview ? nil : question.content, title: notebook.title, pages: pages
        ) else { return request }
        grounding[question.id] = context
        var request = request
        request.insert(AIMessage(role: .system, content: context.text), at: request.count - 1)
        return request
    }

    /// Asks the SAME provider for 2-3 short follow-ups grounded in the real
    /// transcript, as a throwaway extra turn — never appended to `messages`, so
    /// it never shows up as a message and never gets persisted. No backend
    /// change needed: this reuses the exact chat-completion path `send` does,
    /// just with a one-off trailing instruction. A failure or empty result just
    /// leaves `followUpSuggestions` empty; the UI hides the row in that case.
    private func generateFollowUps() {
        // Permission can be withdrawn while a reply is still arriving.
        guard consent.isGranted else { return }
        let request = messages.filter { $0.role != .assistant || !$0.content.isEmpty } + [
            AIMessage(role: .user, content: """
                Suggest exactly 3 short follow-up questions about what we just \
                discussed, one per line, no numbering, each under 6 words.
                """)
        ]
        followUpTask = Task { [provider] in
            var raw = ""
            do {
                for try await token in provider.streamReply(to: request) {
                    if Task.isCancelled { return }
                    raw += token
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            followUpSuggestions = Self.parseFollowUps(NovaReply.display(raw))
        }
    }

    private func removeEmptyAssistant(at index: Int) {
        if index < messages.count, messages[index].role == .assistant, messages[index].content.isEmpty {
            messages.remove(at: index)
        }
    }
}
