import Foundation
import NotesModels

extension NovaConversation {

    /// Where a reply to a grounded question says it came from, or nil for a
    /// reply to a question that carried no notes.
    public func source(ofReply id: UUID) -> NovaReply.Source? {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .assistant,
              let question = messages[..<index].last(where: { $0.role == .user }),
              grounding[question.id] != nil else { return nil }
        return NovaReply.source(of: messages[index].content, existing: knownPages)
    }

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

    /// What the chat says when a reply fails, by cause.
    nonisolated static func failureMessage(for error: Error) -> String {
        switch error {
        case AIError.missingKey:
            return "Sign in to use NOVA."
        case AIError.badResponse(let status) where status == 401 || status == 403:
            // A session token this backend once accepted can go stale mid-
            // session (nothing re-validates it after launch), and a stale
            // token 401s on EVERY request — chat or snip, it doesn't matter.
            // That used to collapse into the same generic "couldn't respond"
            // text as a real outage, which is why it looked like NOVA was
            // broken outright rather than needing a fresh sign-in.
            return "Your session expired — sign out and back in, then ask NOVA again."
        case AIError.badResponse(status: 429):
            // Survived the provider's own retry, so this is a sustained rate
            // limit rather than one unlucky request. "Couldn't respond" reads
            // as NOVA being broken; it is only busy, and waiting actually
            // works — so say that instead.
            return "NOVA is catching up — ask again in a few seconds."
        default:
            return "NOVA couldn't respond. Try again."
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
}

/// A notebook NOVA has been asked to read: its title, and its pages' text
/// numbered the way the app shows them. Read fresh for every question, so a
/// page written after the chat started is part of the next answer.
public struct NovaNotebookSource {
    public let title: String
    public let pages: @MainActor () async -> [NovaGrounding.Page]

    public init(title: String, pages: @escaping @MainActor () async -> [NovaGrounding.Page]) {
        self.title = title
        self.pages = pages
    }
}
