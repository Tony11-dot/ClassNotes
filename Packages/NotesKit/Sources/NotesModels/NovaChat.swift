import Foundation
import SwiftData

/// One saved NOVA conversation. Chats are kept per notebook (and a general one
/// for the library), so closing the sidebar never loses the thread — reopening a
/// notebook restores the last conversation and lists the older ones.
///
/// The transcript is stored as encoded JSON rather than a relationship: it's
/// append-only text the app always reads whole, and a blob keeps SwiftData out of
/// the streaming path.
@Model
public final class NovaChat {
    @Attribute(.unique) public var id: UUID
    /// The notebook this chat belongs to; `nil` = a general chat from the library.
    public var notebookID: UUID?
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Encoded `[NovaChatTurn]`.
    public var transcript: Data

    public init(
        id: UUID = UUID(),
        notebookID: UUID? = nil,
        title: String = NovaChat.untitled,
        createdAt: Date = .now,
        turns: [NovaChatTurn] = []
    ) {
        self.id = id
        self.notebookID = notebookID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.transcript = NovaChatTurn.encode(turns)
    }

    public static let untitled = "New chat"

    public var turns: [NovaChatTurn] {
        get { NovaChatTurn.decode(transcript) }
        set { transcript = NovaChatTurn.encode(newValue) }
    }

    /// One-line preview for the chat list.
    public var preview: String {
        turns.last(where: { $0.role == .assistant })?.content
            ?? turns.first?.content
            ?? "No messages yet"
    }
}

/// One stored turn of a NOVA chat. Deliberately a plain value type so the
/// transcript blob is readable and forward-compatible.
public struct NovaChatTurn: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var id: UUID
    public var role: Role
    public var content: String
    /// True when the user's message carried a circled region from the page.
    public var hasAttachment: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        hasAttachment: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.hasAttachment = hasAttachment
        self.createdAt = createdAt
    }

    static func encode(_ turns: [NovaChatTurn]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(turns)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [NovaChatTurn] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NovaChatTurn].self, from: data)) ?? []
    }

    /// A short title derived from the first user message — what the chat list
    /// shows once a conversation has actually started.
    public static func title(from turns: [NovaChatTurn]) -> String {
        guard let first = turns.first(where: { $0.role == .user }) else { return NovaChat.untitled }
        let cleaned = first.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return NovaChat.untitled }
        return cleaned.count <= 42 ? cleaned : String(cleaned.prefix(41)) + "…"
    }
}
