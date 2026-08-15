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

    @Test("The baked colours are rewritten: ink to the accent, the plate to the surface")
    func recolours() throws {
        // A miniature composition with one fill of each baked colour.
        var doc: [String: Any] = [
            "layers": [
                ["ty": "fl", "c": ["k": LaunchScene.navy + [1.0]]] as [String: Any],
                ["ty": "fl", "c": ["k": LaunchScene.lettering + [1.0]]] as [String: Any],
                ["ty": "fl", "c": ["k": LaunchScene.plate + [1.0]]] as [String: Any],
                // An unrelated colour must be left alone.
                ["ty": "st", "c": ["k": [0.5, 0.2, 0.1, 1]]] as [String: Any]
            ]
        ]
        let accent = try #require(ThemeColor(hex: "#416835"))
        let surface = try #require(ThemeColor(hex: "#101010"))
        LaunchScene.recolour(&doc, from: LaunchScene.lettering, to: accent)
        LaunchScene.recolour(&doc, from: LaunchScene.navy, to: accent)
        LaunchScene.recolour(&doc, from: LaunchScene.plate, to: surface)

        let layers = try #require(doc["layers"] as? [Any])
        func components(_ index: Int) throws -> [Double] {
            let layer = try #require(layers[index] as? [String: Any])
            let colour = try #require(layer["c"] as? [String: Any])
            return try #require(colour["k"] as? [Any]).compactMap { $0 as? Double }
        }

        #expect(abs(try components(0)[0] - accent.red) < 0.001)
        #expect(abs(try components(0)[1] - accent.green) < 0.001)
        // The lettering is INK: it takes the accent, not the background colour.
        #expect(abs(try components(1)[0] - accent.red) < 0.001)
        #expect(abs(try components(1)[2] - accent.blue) < 0.001)
        #expect(abs(try components(2)[0] - surface.red) < 0.001)
        // Alpha rides along untouched.
        #expect(try components(0).count == 4)
        // The colour that matched none of them is exactly as it was.
        #expect(abs(try components(3)[0] - 0.5) < 0.001)
    }

    @Test("The lettering does not come out the colour of the background behind it")
    func letteringNeverMatchesTheSurface() throws {
        // The shipped artwork is white lettering on a near-black plate. Painting
        // white with the theme's SURFACE — the rule the previous artwork needed —
        // makes the words the same colour as the field they sit on, which on a
        // dark theme means a launch with no wordmark in it at all.
        let surface = try #require(ThemeColor(hex: "#101010"))
        let accent = try #require(ThemeColor(hex: "#416835"))
        let data = try #require(LaunchScene.recolouredData(surface: surface, accent: accent))
        let doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        var surfaceInk = 0
        var accentInk = 0
        func walk(_ value: Any) {
            if let map = value as? [String: Any] {
                if let type = map["ty"] as? String, type == "fl" || type == "st",
                   let colour = map["c"] as? [String: Any],
                   let parts = (colour["k"] as? [Any])?.compactMap({ $0 as? Double }),
                   parts.count >= 3 {
                    let near: ([Double]) -> Bool = { target in
                        zip(parts.prefix(3), target).allSatisfy { abs($0 - $1) < 0.001 }
                    }
                    if near([surface.red, surface.green, surface.blue]) { surfaceInk += 1 }
                    if near([accent.red, accent.green, accent.blue]) { accentInk += 1 }
                }
                map.values.forEach(walk)
            } else if let list = value as? [Any] {
                list.forEach(walk)
            }
        }
        walk(doc)

        // The plate — and only the plate — takes the surface colour.
        #expect(surfaceInk == 1, "expected exactly the backing plate to become the surface")
        #expect(accentInk > 10, "the lettering and the brand shapes both take the accent")
    }

    @Test("Every colour the recolourer looks for is really in the shipped artwork")
    func shippedColoursAreRecognised() throws {
        // Re-export the scene and a baked colour moves a digit or two — or, as
        // happened here, the artwork is redrawn and the colour that used to be the
        // canvas is now the lettering. Miss one and the recolouring silently does
        // nothing to it: the artwork still plays, so the only symptom is a launch
        // that ignores the theme, which is the kind of failure nobody notices
        // until it ships.
        let json = try #require(LaunchScene.rawJSON)
        let doc = try #require(
            try JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        var counts: [String: Int] = [:]
        let baked = [
            "navy": LaunchScene.navy,
            "lettering": LaunchScene.lettering,
            "plate": LaunchScene.plate
        ]
        func walk(_ value: Any) {
            if let map = value as? [String: Any] {
                for (key, child) in map {
                    if key == "k", let components = child as? [Any], components.count >= 3 {
                        let values = components.prefix(3).compactMap { $0 as? Double }
                        for (name, target) in baked where values.count == 3
                            && zip(values, target).allSatisfy({
                                abs($0 - $1) <= LaunchScene.colourTolerance
                            }) {
                            counts[name, default: 0] += 1
                        }
                    }
                    walk(child)
                }
            } else if let list = value as? [Any] {
                list.forEach(walk)
            }
        }
        walk(doc)
        for name in baked.keys {
            #expect((counts[name] ?? 0) > 0, "no colour in LaunchScene.json matches \(name)")
        }
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

    @Test("The themed scene is the one that plays — no silent fall back to the baked artwork")
    func themedSceneIsTheOneThatPlays() throws {
        // `animation(surface:accent:)` hands back the UNTOUCHED scene whenever
        // anything in the rewrite fails, and an untouched scene still plays, still
        // lasts the right length and is still non-nil. So the test that only asked
        // for an animation would have passed happily while every theme was being
        // ignored on screen. This asks the question that fallback hides.
        try #require(LaunchScene.isAvailable)
        for preset in ThemePreset.allCases {
            let spec = preset.spec
            #expect(
                LaunchScene.canBuildThemedScene(surface: spec.surface, accent: spec.accent),
                "\(preset) fell back to the baked artwork"
            )
        }
    }

    @Test("Recolouring leaves none of the baked navy behind")
    func recolouringLeavesNoBakedColour() throws {
        let accent = try #require(ThemeColor(hex: "#416835"))
        let surface = try #require(ThemeColor(hex: "#101010"))
        let data = try #require(LaunchScene.recolouredData(surface: surface, accent: accent))
        let doc = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        var bakedFills = 0
        var accentFills = 0
        func walk(_ value: Any) {
            if let map = value as? [String: Any] {
                if let type = map["ty"] as? String, type == "fl" || type == "st",
                   let colour = map["c"] as? [String: Any],
                   let components = (colour["k"] as? [Any])?.compactMap({ $0 as? Double }),
                   components.count >= 3 {
                    let matches: ([Double]) -> Bool = { target in
                        zip(components.prefix(3), target).allSatisfy {
                            abs($0 - $1) <= LaunchScene.colourTolerance
                        }
                    }
                    if matches(LaunchScene.navy) { bakedFills += 1 }
                    if matches([accent.red, accent.green, accent.blue]) { accentFills += 1 }
                }
                map.values.forEach(walk)
            } else if let list = value as? [Any] {
                list.forEach(walk)
            }
        }
        walk(doc)

        #expect(bakedFills == 0, "the artwork's own blue survived the recolour")
        #expect(accentFills > 0, "nothing was recoloured to the theme's accent")
    }
}

/// The launch animation is laid out to FIT, whatever it is offered.
@Suite("Launch scene sizing")
struct LaunchSceneSizingTests {

    @Test("A wide scene fits the width it is offered and never exceeds it")
    func fitsInsideNarrowRoom() {
        // A phone: 393 points across, a whole screen tall. The composition is
        // 1280×720, which is also the animation view's intrinsic size — laid out
        // at that size it runs off both edges, which is exactly how it shipped.
        let size = LaunchScene.fitted(
            aspectRatio: 16.0 / 9.0, into: CGSize(width: 393, height: 852)
        )
        #expect(size.width == 393)
        #expect(abs(size.height - 393 * 9 / 16) < 0.001)
        #expect(size.height <= 852)
    }

    @Test("A short, wide space is fitted by its height instead")
    func fitsInsideShortRoom() {
        let size = LaunchScene.fitted(
            aspectRatio: 16.0 / 9.0, into: CGSize(width: 1000, height: 200)
        )
        #expect(abs(size.height - 200) < 0.001)
        #expect(abs(size.width - 200 * 16 / 9) < 0.001)
        #expect(size.width <= 1000)
    }

    @Test("An unspecified dimension is taken from the one that was given")
    func fitsWithOneDimension() {
        let fromWidth = LaunchScene.fitted(
            aspectRatio: 2, into: CGSize(width: 300, height: 0)
        )
        #expect(fromWidth == CGSize(width: 300, height: 150))
        let fromHeight = LaunchScene.fitted(
            aspectRatio: 2, into: CGSize(width: CGFloat.infinity, height: 100)
        )
        #expect(fromHeight == CGSize(width: 200, height: 100))
        #expect(LaunchScene.fitted(aspectRatio: 2, into: .zero) == .zero)
    }
}
