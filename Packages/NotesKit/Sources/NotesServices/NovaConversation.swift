import Foundation
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

    public static let systemPrompt = AIMessage(
        role: .system,
        content: """
        You are NOVA, a friendly study assistant inside a note-taking app. \
        Explain clearly and concisely, use short paragraphs and lists, and \
        assume the user is a student reviewing their own notes. When given \
        text or a description pulled from the page, explain it in plain language \
        and offer one follow-up they could ask.
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

    public func reset() {
        streamTask?.cancel()
        streaming = false
        errorText = nil
        messages = [Self.systemPrompt]
    }

    private func beginAssistantReply() {
        streaming = true
        var assistant = AIMessage(role: .assistant, content: "")
        messages.append(assistant)
        let index = messages.count - 1
        let request = messages.filter { $0.role != .assistant || !$0.content.isEmpty }

        streamTask = Task { [provider] in
            do {
                for try await token in provider.streamReply(to: request) {
                    assistant.content += token
                    if index < messages.count {
                        messages[index] = assistant
                    }
                }
            } catch AIError.missingKey {
                errorText = "Add a free Groq API key in Settings to use NOVA."
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
