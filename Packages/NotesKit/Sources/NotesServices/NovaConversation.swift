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

    private let provider: AIProvider
    private var streamTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?

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

    /// "Read this notebook": seeds NOVA with a contact-sheet picture of every
    /// page (see `NotebookExporter.contactSheet`) plus each page's recognized
    /// text, and asks for an overview. Mirrors `explainRegion` exactly — same
    /// "picture is what the answer is based on, recognized text just rides
    /// along as a hint" shape, just covering the whole notebook instead of one
    /// snip.
    public func explainNotebook(image: Data, pageCount: Int, textHint: String) {
        errorText = nil
        var prompt = "Here's a contact sheet of all \(pageCount) page"
            + (pageCount == 1 ? "" : "s") + " of my notebook, laid out together. "
            + "Give me a quick overview of what's in it, then answer anything else "
            + "I ask using this as context."
        let hint = textHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty {
            prompt += "\n\n(Recognized text from the pages, in case it helps: \"\(hint)\")"
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
        followUpTask?.cancel()
        streaming = false
        errorText = nil
        followUpSuggestions = []
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
        followUpTask?.cancel()
        streaming = false
        errorText = nil
        followUpSuggestions = []
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
        followUpTask?.cancel()
        followUpSuggestions = []
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
            } catch AIError.missingKey {
                errorText = "Sign in to use NOVA."
                removeEmptyAssistant(at: index)
            } catch let AIError.badResponse(status) where status == 401 || status == 403 {
                // A session token this backend once accepted can go stale mid-
                // session (nothing re-validates it after launch), and a stale
                // token 401s on EVERY request — chat or snip, it doesn't matter.
                // That used to collapse into the same generic "couldn't respond"
                // text as a real outage, which is why it looked like NOVA was
                // broken outright rather than needing a fresh sign-in.
                errorText = "Your session expired — sign out and back in, then ask NOVA again."
                removeEmptyAssistant(at: index)
            } catch AIError.badResponse(status: 429) {
                // Survived the provider's own retry, so this is a sustained rate
                // limit rather than one unlucky request. "Couldn't respond" reads
                // as NOVA being broken; it is only busy, and waiting actually
                // works — so say that instead.
                errorText = "NOVA is catching up — ask again in a few seconds."
                removeEmptyAssistant(at: index)
            } catch {
                errorText = "NOVA couldn't respond. Try again."
                removeEmptyAssistant(at: index)
            }
            streaming = false
        }
    }

    /// Asks the SAME provider for 2-3 short follow-ups grounded in the real
    /// transcript, as a throwaway extra turn — never appended to `messages`, so
    /// it never shows up as a message and never gets persisted. No backend
    /// change needed: this reuses the exact chat-completion path `send` does,
    /// just with a one-off trailing instruction. A failure or empty result just
    /// leaves `followUpSuggestions` empty; the UI hides the row in that case.
    private func generateFollowUps() {
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

    /// Splits a raw "one suggestion per line" reply into up to 3 clean, tappable
    /// strings — stripping numbering/bullet prefixes the model adds despite being
    /// asked not to, and dropping blank lines.
    static func parseFollowUps(_ raw: String) -> [String] {
        var results: [String] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: #"^(\d+[.)]|[-•*])\s*"#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            results.append(line)
            if results.count == 3 { break }
        }
        return results
    }

    private func removeEmptyAssistant(at index: Int) {
        if index < messages.count, messages[index].role == .assistant, messages[index].content.isEmpty {
            messages.remove(at: index)
        }
    }
}
