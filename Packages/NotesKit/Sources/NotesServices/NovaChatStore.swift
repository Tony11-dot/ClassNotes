import Foundation
import NotesModels
import Observation
import SwiftData

/// Saved NOVA conversations.
///
/// A chat is created the first time a notebook's NOVA sidebar is used and kept
/// updated as the conversation grows, so closing the sidebar — or the notebook —
/// never loses the thread. Each notebook has its own list; the most recent one is
/// what reopens.
///
/// Writes are debounced by the caller (the conversation streams token by token);
/// this type just owns the SwiftData rows.
@MainActor
@Observable
public final class NovaChatStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Every chat for one notebook (or the library's general chats when nil),
    /// most recently updated first.
    public func chats(notebookID: UUID?) -> [NovaChat] {
        // Fetch-all-then-filter: the set is tiny, and predicate machinery over an
        // optional UUID traps on hostless test runners.
        let all = (try? context.fetch(FetchDescriptor<NovaChat>())) ?? []
        return all
            .filter { $0.notebookID == notebookID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The chat a notebook should reopen: its most recent one, if it has any.
    public func mostRecent(notebookID: UUID?) -> NovaChat? {
        chats(notebookID: notebookID).first
    }

    @discardableResult
    public func create(notebookID: UUID?, title: String = NovaChat.untitled) -> NovaChat {
        let chat = NovaChat(notebookID: notebookID, title: title)
        context.insert(chat)
        try? context.save()
        return chat
    }

    /// Replaces a chat's transcript and re-titles it from the first question.
    public func save(_ chat: NovaChat, turns: [NovaChatTurn]) {
        chat.turns = turns
        chat.updatedAt = .now
        if chat.title == NovaChat.untitled {
            chat.title = NovaChatTurn.title(from: turns)
        }
        try? context.save()
    }

    public func rename(_ chat: NovaChat, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.title = trimmed
        chat.updatedAt = .now
        try? context.save()
    }

    public func delete(_ chat: NovaChat) {
        context.delete(chat)
        try? context.save()
    }

    /// Removes every chat belonging to a notebook — called when it's deleted, so
    /// transcripts don't outlive the notes they were about.
    public func deleteChats(notebookID: UUID) {
        for chat in chats(notebookID: notebookID) {
            context.delete(chat)
        }
        try? context.save()
    }
}
