import CoreGraphics
import Foundation
import NotesModels
import Testing
@testable import NotesServices

@Suite("Groq SSE parsing + AI provider")
struct AIServiceTests {
    @Test("Delta extraction from SSE lines")
    func sseDelta() {
        #expect(GroqProvider.delta(fromSSELine: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#) == "Hi")
        #expect(GroqProvider.delta(fromSSELine: "data: [DONE]") == nil)
        #expect(GroqProvider.delta(fromSSELine: "data:") == nil)
        #expect(GroqProvider.delta(fromSSELine: ": keep-alive") == nil)
        #expect(GroqProvider.delta(fromSSELine: #"data: {"choices":[{"delta":{}}]}"#) == nil)
    }

    @Test("Request carries model, stream flag, bearer key and messages")
    func requestShape() throws {
        let provider = GroqProvider(keychain: InMemorySecretStore())
        let request = try provider.makeRequest(
            messages: [AIMessage(role: .user, content: "hello")],
            key: "gsk_test"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk_test")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == GroqProvider.defaultModel)
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.first?["content"] == "hello")
    }

    @Test("Provider reflects whether a key is stored")
    func configuration() {
        let secrets = InMemorySecretStore()
        let provider = GroqProvider(keychain: secrets)
        // Assumes no GROQ_API_KEY in the environment of the test runner.
        if AIConfig.apiKey(secrets: InMemorySecretStore()).isEmpty {
            #expect(!provider.isConfigured)
        }
        secrets.set("gsk_x", for: .groqAPIKey)
        #expect(provider.isConfigured)
    }

    @Test("AIConfig mirrors ClassMate's Groq defaults and key fallback")
    func configDefaults() {
        #expect(AIConfig.defaultBaseURL == "https://api.groq.com/openai/v1")
        #expect(AIConfig.defaultModel == "llama-3.3-70b-versatile")
        #expect(AIConfig.chatCompletionsURL.absoluteString
            == "https://api.groq.com/openai/v1/chat/completions")
        // Keychain key is the fallback when no env/plist key is set.
        let secrets = InMemorySecretStore()
        secrets.set("gsk_kc", for: .groqAPIKey)
        if AIConfig.apiKey(secrets: InMemorySecretStore()).isEmpty {
            #expect(AIConfig.apiKey(secrets: secrets) == "gsk_kc")
        }
    }
}

@MainActor
@Suite("NovaConversation")
struct NovaConversationTests {
    struct FakeProvider: AIProvider {
        let tokens: [String]
        var isConfigured: Bool { true }
        func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                for token in tokens { continuation.yield(token) }
                continuation.finish()
            }
        }
    }

    struct FailingProvider: AIProvider {
        var isConfigured: Bool { false }
        func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish(throwing: AIError.missingKey) }
        }
    }

    /// Waits (bounded) for the streaming task to settle.
    private func waitUntilIdle(_ nova: NovaConversation) async {
        for _ in 0..<200 where nova.streaming {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Streaming assembles tokens into the assistant message")
    func streaming() async {
        let nova = NovaConversation(provider: FakeProvider(tokens: ["Hel", "lo!"]))
        nova.send("hi")
        await waitUntilIdle(nova)
        #expect(nova.visibleMessages.last?.role == .assistant)
        #expect(nova.visibleMessages.last?.content == "Hello!")
    }

    @Test("explain seeds a user turn from page context")
    func explain() async {
        let nova = NovaConversation(provider: FakeProvider(tokens: ["ok"]))
        nova.explain(context: "photosynthesis")
        await waitUntilIdle(nova)
        #expect(nova.visibleMessages.first?.role == .user)
        #expect(nova.visibleMessages.first?.content.contains("photosynthesis") == true)
    }

    @Test("Missing key surfaces a helpful error, no dangling assistant bubble")
    func missingKey() async {
        let nova = NovaConversation(provider: FailingProvider())
        nova.send("hi")
        await waitUntilIdle(nova)
        #expect(nova.errorText != nil)
        #expect(nova.visibleMessages.allSatisfy { $0.role == .user })
    }
}

@Suite("OCR assembly + content models")
struct ContentModelTests {
    @Test("OCR lines assemble top-to-bottom (Vision bottom-left origin)")
    func ocrAssembly() {
        let lines = [
            OCRService.Line(text: "second", boundingBox: CGRect(x: 0, y: 0.4, width: 1, height: 0.1)),
            OCRService.Line(text: "first", boundingBox: CGRect(x: 0, y: 0.8, width: 1, height: 0.1))
        ]
        #expect(OCRService.assemble(lines) == "first\nsecond")
    }

    @Test("Manifest round-trips page elements at the current version")
    func elementsRoundTrip() throws {
        let element = PageElement(
            kind: .text, x: 10, y: 20, width: 400, height: 120,
            text: "Newton's second law", fontName: "Cabinet Grotesk", textColorHex: "#181C20"
        )
        let manifest = NotebookManifest(pages: [PageRecord(template: .ruled, elements: [element])])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NotebookManifest.self, from: encoder.encode(manifest))
        #expect(decoded.version == NotebookManifest.currentVersion)
        #expect(decoded.pages.first?.elements.first?.text == "Newton's second law")
        #expect(decoded.pages.first?.elements.first?.kind == .text)
    }

    @Test("v1 manifest (no elements key) decodes with empty elements")
    func v1BackwardCompatible() throws {
        let json = """
        {"version":1,"pages":[{"id":"\(UUID().uuidString)","template":"grid",
        "createdAt":"2026-07-24T00:00:00Z"}]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(NotebookManifest.self, from: Data(json.utf8))
        #expect(manifest.pages.first?.elements.isEmpty == true)
        #expect(manifest.pages.first?.template == .grid)
    }
}

@Suite("Secret store")
struct SecretStoreTests {
    @Test("In-memory store round-trips and clears a value")
    func roundTrip() {
        let store = InMemorySecretStore()
        #expect(store.get(.groqAPIKey) == nil)
        store.set("gsk_secret", for: .groqAPIKey)
        #expect(store.get(.groqAPIKey) == "gsk_secret")
        store.set("", for: .groqAPIKey) // empty clears
        #expect(store.get(.groqAPIKey) == nil)
    }
}
