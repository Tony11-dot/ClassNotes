import Foundation

public struct AIMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public var id: UUID
    public var role: Role
    public var content: String
    /// Optional attached image (JPEG/PNG data). When present, the provider
    /// routes the whole exchange to a vision-capable model — this is how the
    /// magic pen sends a circled region (text OR picture) as the prompt.
    public var imageData: Data?

    public init(id: UUID = UUID(), role: Role, content: String, imageData: Data? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.imageData = imageData
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

/// Groq (free, OpenAI-compatible), configured exactly like ClassMate — see
/// `AIConfig` for the env-var names and resolution order. The key comes from
/// env / build-injected Info.plist / the user's Keychain, never from source.
public struct GroqProvider: AIProvider {
    /// A strong free model on Groq — same default as ClassMate.
    public static let defaultModel = AIConfig.defaultModel

    private let keychain: any SecretStore
    private let session: URLSession
    private let modelOverride: String?

    public init(
        keychain: any SecretStore = KeychainStore(),
        session: URLSession = .shared,
        model: String? = nil
    ) {
        self.keychain = keychain
        self.session = session
        self.modelOverride = model
    }

    private var model: String { modelOverride ?? AIConfig.model() }

    public var isConfigured: Bool {
        if AIConfig.isProxy { return !(keychain.get(.authToken) ?? "").isEmpty }
        return !AIConfig.apiKey(secrets: keychain).isEmpty || AIConfig.isKeylessLocal()
    }

    /// The Authorization bearer: in proxy mode this is the user's ClassMate
    /// session token (the proxy holds the Groq key server-side); otherwise it's
    /// the Groq key itself (env / build-injected / user's Keychain).
    private var bearer: String {
        AIConfig.isProxy ? (keychain.get(.authToken) ?? "") : AIConfig.apiKey(secrets: keychain)
    }

    public func makeRequest(messages: [AIMessage], key: String) throws -> URLRequest {
        var request = URLRequest(url: AIConfig.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        // Any attached image routes to the vision model, with content sent as
        // the OpenAI-compatible parts array ({type:text} + {type:image_url}).
        let hasImage = messages.contains { $0.imageData != nil }
        let payloadMessages: [[String: Any]] = messages.map { message in
            guard let data = message.imageData else {
                return ["role": message.role.rawValue, "content": message.content]
            }
            let dataURL = "data:image/jpeg;base64,\(data.base64EncodedString())"
            return [
                "role": message.role.rawValue,
                "content": [
                    ["type": "text", "text": message.content],
                    ["type": "image_url", "image_url": ["url": dataURL]]
                ]
            ]
        }
        let payload: [String: Any] = [
            "model": hasImage ? AIConfig.visionModel() : model,
            "stream": true,
            "temperature": 0.4,
            "messages": payloadMessages
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
                let key = bearer
                guard !key.isEmpty else {
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
