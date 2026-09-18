import Foundation
import os

private let novaLog = Logger(subsystem: "com.classmate.notes", category: "Nova")

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

    /// Statuses where the request itself was fine and the server was only
    /// momentarily unwilling — worth asking once more. Everything else (400,
    /// 401, 404) is a contract or auth problem that a retry just repeats.
    static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]

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

        // The most recent snip in the conversation travels with EVERY turn about
        // it, not only the first. The endpoint keeps no state, so a follow-up that
        // left the picture behind would be answered from the model's memory of a
        // description — which is how "and why is that arrow there?" gets a
        // confident answer about the wrong thing.
        if let image = messages.last(where: { $0.imageData != nil })?.imageData,
           !image.isEmpty {
            payload["task"] = "see"
            payload["imageBase64"] = image.base64EncodedString()
        }
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
        // A snip's `task: "see"` request carries a base64 image and waits on a
        // vision model, which is routinely slower than a plain chat turn —
        // explicit and generous so a genuinely slow (not stuck) inference
        // doesn't get cut off right as it was about to answer.
        request.timeoutInterval = 90
        return request
    }

    /// One attempt at the whole round trip: request, status check, body decode.
    /// Every failure is thrown with its real cause LOGGED (subsystem
    /// `com.classmate.notes`/category `Nova`) before being collapsed to the
    /// small `AIError` surface the UI understands — collapsing straight to
    /// `.network` with nothing recorded anywhere is why "NOVA couldn't
    /// respond" was reported with no way to tell a timeout, a bad response
    /// shape, and a dropped connection apart afterward.
    private func attempt(messages: [AIMessage], token: String) async throws -> String {
        let request = try makeRequest(messages: messages, token: token)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8 body>"
            novaLog.error("NOVA backend returned status \(status): \(body, privacy: .public)")
            throw AIError.badResponse(status: status)
        }
        guard let answer = Self.answer(from: data) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8 body>"
            novaLog.error("NOVA backend returned an unparseable body (status \(status)): \(body, privacy: .public)")
            throw AIError.badResponse(status: status)
        }
        return answer
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
                    let answer: String
                    do {
                        answer = try await attempt(messages: messages, token: token)
                    } catch let AIError.badResponse(status) where Self.retryableStatuses.contains(status) {
                        // A bad response SHAPE is a server/contract problem, not a
                        // blip — retrying it just asks the same broken question
                        // again. But a 429 or a 5xx is the opposite: the request
                        // was fine and the server was momentarily unwilling.
                        //
                        // 429 in particular is routine rather than exceptional
                        // here. The endpoint allows 20 requests a minute and
                        // every visible turn spends TWO of them — the reply, plus
                        // the throwaway call `generateFollowUps` makes for the
                        // suggestion chips — so a student typing briskly can be
                        // rate-limited after ~10 questions and be told NOVA
                        // "couldn't respond", which reads as broken rather than
                        // busy. Waiting a beat and asking once more is usually
                        // the whole fix.
                        novaLog.error("NOVA backend returned \(status), retrying once")
                        try? await Task.sleep(for: .milliseconds(status == 429 ? 1200 : 400))
                        guard !Task.isCancelled else { throw AIError.network }
                        answer = try await attempt(messages: messages, token: token)
                    } catch let error as AIError {
                        throw error
                    } catch {
                        novaLog.error("NOVA request failed, retrying once: \(String(describing: error), privacy: .public)")
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { throw AIError.network }
                        answer = try await attempt(messages: messages, token: token)
                    }
                    for chunk in Self.chunks(of: answer) {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                        try? await Task.sleep(for: .milliseconds(12))
                    }
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    novaLog.error("NOVA request failed after retry: \(String(describing: error), privacy: .public)")
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
/// The backend answers everything it can, because it needs no key on the device
/// and its model is updated server-side — snips included: `/classnotes/ai` now
/// takes the picture and routes it to a vision model with the key kept on the
/// server. Groq direct survives only as a fallback for a user who has entered
/// their own key and has no session, which is not a state the app can normally
/// reach.
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
        if backend.isConfigured { return backend }
        return direct
    }

    public func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        provider(for: messages).streamReply(to: messages)
    }
}
