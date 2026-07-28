import ClassMateTheme
import Foundation
import Testing
@testable import NotesDesignSystem
@testable import NotesServices

/// NOVA answering through ClassMate's own backend — the path that needs no key on
/// the device, and so can't be broken by a revoked key or a retired model.
@Suite("NOVA through the ClassMate backend")
struct NovaBackendTests {

    @Test("Available to anyone signed in; unavailable with no session")
    func configuredFollowsTheSession() {
        let secrets = InMemorySecretStore()
        let provider = NovaBackendProvider(keychain: secrets)
        #expect(!provider.isConfigured, "no session, no NOVA")

        secrets.set("jwt-token", for: .authToken)
        #expect(provider.isConfigured)
    }

    @Test("The exchange maps onto the endpoint's task/text/history/context shape")
    func payloadShape() throws {
        let payload = NovaBackendProvider.payload(for: [
            AIMessage(role: .system, content: "the page says photosynthesis"),
            AIMessage(role: .user, content: "what is it?"),
            AIMessage(role: .assistant, content: "a process"),
            AIMessage(role: .user, content: "explain more")
        ])

        #expect(payload["task"] as? String == "chat")
        // The QUESTION is the last user turn, not the whole transcript.
        #expect(payload["text"] as? String == "explain more")
        #expect(payload["pageContext"] as? String == "the page says photosynthesis")

        let history = try #require(payload["history"] as? [[String: String]])
        // Everything before the question, system prompts excluded — those went to
        // pageContext, and sending them twice would double the prompt.
        #expect(history.count == 2)
        #expect(history[0]["role"] == "user")
        #expect(history[0]["content"] == "what is it?")
        #expect(history[1]["role"] == "assistant")
    }

    @Test("A first message carries no history and no context")
    func firstMessageIsBare() {
        let payload = NovaBackendProvider.payload(for: [
            AIMessage(role: .user, content: "hello")
        ])
        #expect(payload["text"] as? String == "hello")
        #expect(payload["history"] == nil)
        #expect(payload["pageContext"] == nil)
    }

    @Test("The answer is read out of the endpoint's body")
    func readsAnswer() {
        let good = Data(#"{"answer":"Photosynthesis is..."}"#.utf8)
        #expect(NovaBackendProvider.answer(from: good) == "Photosynthesis is...")
        #expect(NovaBackendProvider.answer(from: Data(#"{"error":"nope"}"#.utf8)) == nil)
        #expect(NovaBackendProvider.answer(from: Data("not json".utf8)) == nil)
    }

    @Test("A whole answer is delivered in pieces, losing nothing")
    func chunkingPreservesTheAnswer() {
        let answer = "Photosynthesis turns light into sugar.\nIt happens in chloroplasts."
        let chunks = NovaBackendProvider.chunks(of: answer)
        #expect(chunks.count > 5, "a single chunk isn't a stream")
        #expect(chunks.joined() == answer, "the text must survive being cut up")
        #expect(NovaBackendProvider.chunks(of: "").isEmpty)
    }

    @Test("Routing prefers the backend, and only uses a direct key for images")
    func routing() {
        let secrets = InMemorySecretStore()
        secrets.set("jwt", for: .authToken)
        secrets.set("gsk_key", for: .groqAPIKey)
        let router = NovaProviderRouter(
            backend: NovaBackendProvider(keychain: secrets),
            direct: GroqProvider(keychain: secrets)
        )

        #expect(router.isConfigured)
        // Plain chat: the backend, because it needs no key on the device.
        let text = [AIMessage(role: .user, content: "hi")]
        #expect(router.provider(for: text) is NovaBackendProvider)

        // The magic pen sends a REGION; the endpoint takes text only.
        let withImage = [AIMessage(role: .user, content: "what is this?", imageData: Data([0x1]))]
        #expect(router.provider(for: withImage) is GroqProvider)
    }

    @Test("With no session at all, NOVA is unconfigured rather than silently broken")
    func noSession() {
        let secrets = InMemorySecretStore()
        let router = NovaProviderRouter(
            backend: NovaBackendProvider(keychain: secrets),
            direct: GroqProvider(keychain: secrets)
        )
        if AIConfig.apiKey(secrets: InMemorySecretStore()).isEmpty {
            #expect(!router.isConfigured)
        }
    }
}

/// The launch scene follows the theme the way ClassMate's splash does.
@MainActor
@Suite("Launch scene theming")
struct LaunchSceneThemingTests {

    @Test("The baked navy and white are rewritten to the theme's accent and surface")
    func recolours() throws {
        // A miniature composition with one fill of each baked colour.
        var doc: [String: Any] = [
            "layers": [
                ["ty": "fl", "c": ["k": [0.047, 0.098, 0.576, 1]]] as [String: Any],
                ["ty": "fl", "c": ["k": [1.0, 1.0, 1.0, 1]]] as [String: Any],
                // An unrelated colour must be left alone.
                ["ty": "st", "c": ["k": [0.5, 0.2, 0.1, 1]]] as [String: Any]
            ]
        ]
        let accent = try #require(ThemeColor(hex: "#416835"))
        let surface = try #require(ThemeColor(hex: "#101010"))
        LaunchScene.recolour(&doc, from: LaunchScene.white, to: surface)
        LaunchScene.recolour(&doc, from: LaunchScene.navy, to: accent)

        let layers = try #require(doc["layers"] as? [Any])
        func components(_ index: Int) throws -> [Double] {
            let layer = try #require(layers[index] as? [String: Any])
            let colour = try #require(layer["c"] as? [String: Any])
            return try #require(colour["k"] as? [Any]).compactMap { $0 as? Double }
        }

        #expect(abs(try components(0)[0] - accent.red) < 0.001)
        #expect(abs(try components(0)[1] - accent.green) < 0.001)
        #expect(abs(try components(1)[0] - surface.red) < 0.001)
        // Alpha rides along untouched.
        #expect(try components(0).count == 4)
        // The colour that matched neither is exactly as it was.
        #expect(abs(try components(2)[0] - 0.5) < 0.001)
    }

    @Test("The shipped scene recolours for every preset without falling over")
    func recoloursEveryPreset() throws {
        try #require(LaunchScene.isAvailable)
        for preset in ThemePreset.allCases {
            let spec = preset.spec
            let animation = LaunchScene.animation(surface: spec.surface, accent: spec.accent)
            #expect(animation != nil, "\(preset) produced no launch animation")
            #expect((animation?.duration ?? 0) > 1)
        }
    }
}
