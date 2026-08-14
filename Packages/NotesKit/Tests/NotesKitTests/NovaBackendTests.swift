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

    @Test("A snip is sent as a picture, and stays attached to its follow-ups")
    func snipPayload() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let payload = NovaBackendProvider.payload(for: [
            AIMessage(role: .user, content: "what is this?", imageData: jpeg)
        ])
        #expect(payload["task"] as? String == "see")
        #expect(payload["imageBase64"] as? String == jpeg.base64EncodedString())

        // The follow-up carries no image of its own — but it is ABOUT the snip, so
        // the picture goes with it. Dropping it here is how a second question gets
        // answered from a description instead of from the page.
        let followUp = NovaBackendProvider.payload(for: [
            AIMessage(role: .user, content: "what is this?", imageData: jpeg),
            AIMessage(role: .assistant, content: "A free-body diagram."),
            AIMessage(role: .user, content: "why is that arrow there?")
        ])
        #expect(followUp["text"] as? String == "why is that arrow there?")
        #expect(followUp["imageBase64"] as? String == jpeg.base64EncodedString())
        #expect((followUp["history"] as? [[String: String]])?.count == 2)

        // A conversation with no picture in it stays a plain chat.
        let text = NovaBackendProvider.payload(for: [AIMessage(role: .user, content: "hi")])
        #expect(text["task"] as? String == "chat")
        #expect(text["imageBase64"] == nil)
    }

    @Test("Everything routes through the backend, snips included")
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

        // A snip too, now the endpoint can see. Sending it to Groq direct meant it
        // only worked for a user who had pasted their own key — which is to say,
        // for almost nobody.
        let withImage = [AIMessage(role: .user, content: "what is this?", imageData: Data([0x1]))]
        #expect(router.provider(for: withImage) is NovaBackendProvider)
    }

    @Test("A snip is shrunk to something a model reads and a phone can upload")
    func snipEncoding() {
        // Never blown up: a small crop stays exactly as it was rendered.
        #expect(NovaSnip.downscale(for: CGSize(width: 400, height: 300)) == 1)
        // A full 2× page render is far bigger than any vision model samples.
        let factor = NovaSnip.downscale(for: CGSize(width: 3200, height: 2400))
        #expect(factor < 1)
        #expect(abs(3200 * factor - NovaSnip.maximumSide) < 0.5, "the long side lands on the cap")
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
                ["ty": "fl", "c": ["k": LaunchScene.navy + [1.0]]] as [String: Any],
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

    @Test("The blue in the shipped artwork is the blue the recolourer looks for")
    func shippedColoursAreRecognised() throws {
        // Re-export the scene and its brand blue moves a digit or two. Miss it and
        // the recolouring silently does nothing — the artwork still plays, so the
        // only symptom is a launch that ignores the theme, which is exactly the
        // kind of failure nobody notices until it ships.
        let json = try #require(LaunchScene.rawJSON)
        let doc = try #require(
            try JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        var found = false
        func walk(_ value: Any) {
            if let map = value as? [String: Any] {
                for (key, child) in map {
                    if key == "k", let components = child as? [Any], components.count >= 3 {
                        let values = components.prefix(3).compactMap { $0 as? Double }
                        if values.count == 3,
                           zip(values, LaunchScene.navy).allSatisfy({
                               abs($0 - $1) <= LaunchScene.colourTolerance
                           }) {
                            found = true
                        }
                    }
                    walk(child)
                }
            } else if let list = value as? [Any] {
                list.forEach(walk)
            }
        }
        walk(doc)
        #expect(found, "no colour in LaunchScene.json matches LaunchScene.navy")
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
