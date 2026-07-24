import Foundation

public struct AIMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public var id: UUID
    public var role: Role
    public var content: String

    public init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

public enum AIError: Error, Equatable, Sendable {
    case missingKey
    case badResponse(status: Int)
    case network
}

/// A streaming chat provider. Swappable so the same NOVA UI can later point at
/// a backend proxy instead of calling the model directly.
public protocol AIProvider: Sendable {
    var isConfigured: Bool { get }
    func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error>
}

/// Groq (free, OpenAI-compatible). The API key lives in the Keychain and is
/// entered by the user in Settings — it is never embedded in source.
public struct GroqProvider: AIProvider {
    public static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    /// A strong free model on Groq. Kept in one place so it's easy to change.
    public static let defaultModel = "llama-3.3-70b-versatile"

    private let keychain: any SecretStore
    private let session: URLSession
    private let model: String

    public init(
        keychain: any SecretStore = KeychainStore(),
        session: URLSession = .shared,
        model: String = GroqProvider.defaultModel
    ) {
        self.keychain = keychain
        self.session = session
        self.model = model
    }

    public var isConfigured: Bool {
        !(keychain.get(.groqAPIKey) ?? "").isEmpty
    }

    public func makeRequest(messages: [AIMessage], key: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.4,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Extracts the incremental token from one SSE `data:` line. Returns nil for
    /// keep-alives, the `[DONE]` sentinel, and unparseable lines.
    public static func delta(fromSSELine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }

    public func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let key = keychain.get(.groqAPIKey), !key.isEmpty else {
                    continuation.finish(throwing: AIError.missingKey)
                    return
                }
                do {
                    let request = try makeRequest(messages: messages, key: key)
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard (200..<300).contains(status) else {
                        continuation.finish(throwing: AIError.badResponse(status: status))
                        return
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let token = Self.delta(fromSSELine: line) {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.network)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
