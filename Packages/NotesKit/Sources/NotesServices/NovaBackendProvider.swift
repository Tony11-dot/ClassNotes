import Foundation

/// NOVA through ClassMate's own backend (`POST /classnotes/ai`), which holds the
/// model key server-side.
///
/// This is the DEFAULT way NOVA answers, and it exists because the alternative
/// doesn't survive contact with a shipped build: calling Groq directly needs a
/// key in the binary, and a key in the binary is one revocation (or one model
/// deprecation) away from "NOVA isn't working" for everybody, with no way to fix
/// it but another release. The backend is already deployed, already authenticated
/// with the same session the library uses, and already the thing the ClassMate
/// ClassNotes tab talks to.
///
/// It answers in one shot rather than streaming, so the reply is handed to the
/// UI in small pieces to keep NOVA's typing feel.
public struct NovaBackendProvider: AIProvider {
    private let keychain: any SecretStore
    private let session: URLSession
    private let baseURL: URL

    public init(
        keychain: any SecretStore = KeychainStore(),
        session: URLSession = .shared,
        baseURL: URL = ClassMateAPI.baseURL()
    ) {
        self.keychain = keychain
        self.session = session
        self.baseURL = baseURL
    }

    /// Available to anyone signed in — which the library already requires.
    public var isConfigured: Bool {
        !(keychain.get(.authToken) ?? "").isEmpty
    }

    var endpoint: URL { baseURL.appendingPathComponent("classnotes/ai") }

    /// Splits `messages` the way the endpoint expects: a task, the latest
    /// question, the turns before it, and any system prompt as page context.
    ///
    /// Exposed for tests — the mapping is the whole contract with the server.
    public static func payload(for messages: [AIMessage]) -> [String: Any] {
        let question = messages.last(where: { $0.role == .user })?.content ?? ""
        let context = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        // Everything before the question, as plain turns.
        var history: [[String: String]] = []
        if let index = messages.lastIndex(where: { $0.role == .user }) {
            history = messages[..<index]
                .filter { $0.role != .system }
                .map { ["role": $0.role.rawValue, "content": $0.content] }
        }

        var payload: [String: Any] = ["task": "chat", "text": question]
        if !context.isEmpty { payload["pageContext"] = context }
        if !history.isEmpty { payload["history"] = history }
        return payload
    }

    /// The answer out of the endpoint's `{ "answer": ... }` body.
    public static func answer(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = json["answer"] as? String else { return nil }
        return answer
    }

    func makeRequest(messages: [AIMessage], token: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.payload(for: messages)
        )
        return request
    }

    public func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let token = keychain.get(.authToken) ?? ""
                guard !token.isEmpty else {
                    continuation.finish(throwing: AIError.missingKey)
                    return
                }
                do {
                    let request = try makeRequest(messages: messages, token: token)
                    let (data, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard (200..<300).contains(status) else {
                        continuation.finish(throwing: AIError.badResponse(status: status))
                        return
                    }
                    guard let answer = Self.answer(from: data) else {
                        continuation.finish(throwing: AIError.badResponse(status: status))
                        return
                    }
                    for chunk in Self.chunks(of: answer) {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                        try? await Task.sleep(for: .milliseconds(12))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.network)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A whole answer, cut into word-sized pieces so it arrives the way a
    /// streamed one does. Pure, so the split is pinned by tests.
    public static func chunks(of answer: String) -> [String] {
        guard !answer.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        for character in answer {
            current.append(character)
            if character == " " || character == "\n" {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Picks how NOVA answers for a given exchange.
///
/// The backend is preferred because it needs no key on the device and its model
/// is updated server-side. Groq is used when the user has supplied their own key
/// AND the backend can't serve the request — which today means image prompts:
/// the magic pen sends a circled REGION, and `/classnotes/ai` takes text only.
public struct NovaProviderRouter: AIProvider {
    private let backend: NovaBackendProvider
    private let direct: GroqProvider

    public init(keychain: any SecretStore = KeychainStore(), session: URLSession = .shared) {
        self.backend = NovaBackendProvider(keychain: keychain, session: session)
        self.direct = GroqProvider(keychain: keychain, session: session)
    }

    public init(backend: NovaBackendProvider, direct: GroqProvider) {
        self.backend = backend
        self.direct = direct
    }

    public var isConfigured: Bool { backend.isConfigured || direct.isConfigured }

    /// Which provider answers this exchange.
    public func provider(for messages: [AIMessage]) -> any AIProvider {
        let needsVision = messages.contains { $0.imageData != nil }
        if needsVision, direct.isConfigured { return direct }
        if backend.isConfigured { return backend }
        return direct
    }

    public func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        provider(for: messages).streamReply(to: messages)
    }
}
