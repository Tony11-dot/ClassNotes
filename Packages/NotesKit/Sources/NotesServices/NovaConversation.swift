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

    private let provider: AIProvider
    private var streamTask: Task<Void, Never>?

    /// The fallback identity. In proxy mode the server replaces this with NOVA's
    /// authoritative prompt, so keep the two in step (`ai.service.ts`).
    public static let systemPrompt = AIMessage(
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

    public init(provider: AIProvider) {
        self.provider = provider
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
        errorText = nil
        messages.append(AIMessage(role: .user, content: trimmed))
        beginAssistantReply()
    }

    /// Seeds the conversation with page-derived context (circle-to-explain) and
    /// immediately asks for an explanation.
    public func explain(context: String) {
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
        messages = Array(messages[..<index]) + [AIMessage(id: id, role: .user, content: trimmed)]
        beginAssistantReply()
    }

    public func reset() {
        streamTask?.cancel()
        streaming = false
        errorText = nil
        messages = [Self.systemPrompt]
    }

    // MARK: - Persistence bridge (saved chats)

    /// The transcript in the shape `NovaChatStore` persists. Empty assistant
    /// placeholders (a stream that failed) are dropped.
    public var storedTurns: [NovaChatTurn] {
        visibleMessages.compactMap { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return NovaChatTurn(
                id: message.id,
                role: message.role == .user ? .user : .assistant,
                content: message.content,
                hasAttachment: message.imageData != nil
            )
        }
    }

    /// Reloads a saved chat. Attached images aren't kept (they were page crops, not
    /// conversation state), so a restored turn carries its text alone.
    public func restore(turns: [NovaChatTurn]) {
        streamTask?.cancel()
        streaming = false
        errorText = nil
        messages = [Self.systemPrompt] + turns.map { turn in
            AIMessage(
                id: turn.id,
                role: turn.role == .user ? .user : .assistant,
                content: turn.content
            )
        }
    }

    private func beginAssistantReply() {
        // Cancel any in-flight stream so two replies can never interleave into
        // the transcript (e.g. explain() seeded while a send() is still running).
        streamTask?.cancel()
        streaming = true
        var assistant = AIMessage(role: .assistant, content: "")
        messages.append(assistant)
        let index = messages.count - 1
        let request = messages.filter { $0.role != .assistant || !$0.content.isEmpty }

        streamTask = Task { [provider] in
            do {
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
            } catch AIError.missingKey {
                errorText = "Sign in to use NOVA."
                removeEmptyAssistant(at: index)
            } catch {
                errorText = "NOVA couldn't respond. Try again."
                removeEmptyAssistant(at: index)
            }
            streaming = false
        }
    }

    private func removeEmptyAssistant(at index: Int) {
        if index < messages.count, messages[index].role == .assistant, messages[index].content.isEmpty {
            messages.remove(at: index)
        }
    }
}
