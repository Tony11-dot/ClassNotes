import ClassMateTheme
import Lottie
import SwiftUI
import UIKit

/// The designed launch animation — the Lottie scene exported from Jitter — played
/// once, then handed off.
///
/// The app used to rebuild this scene by hand in SwiftUI, which meant the launch
/// was a *likeness* of the artwork that drifted every time the artwork changed.
/// Shipping the `.json` itself makes the animation the source of truth: replacing
/// `Resources/LaunchScene.json` replaces the launch.
///
/// The scene is RECOLOURED to the active theme before it plays, exactly the way
/// ClassMate does it (`splash_screen.dart`): everything the artwork draws — the
/// lettering, the brand-blue decor, the CN monogram — becomes the theme's accent,
/// and the plate they are drawn on becomes the theme's surface, so the lockup
/// melts into the background. The monogram is an embedded PNG inside the
/// composition, which vector recolouring can't reach, so its pixels are retinted
/// separately with the alpha preserved. On the plain light theme this is close to
/// identity, so the original blue splash survives.
public enum LaunchScene {
    /// The three colours baked into the artwork.
    ///
    /// The scene is a lockup — white "ClassNotes" lettering on a near-black
    /// plate — plus the brand blue of the mark and the decor around it. So white
    /// here is INK, not background: it is what the words are drawn in, and the
    /// plate is what they sit on.
    ///
    /// That is the reverse of the artwork this recolourer was first written for,
    /// which was a navy mark on a white canvas — and it is why the launch stopped
    /// following the theme. `lettering` was being painted the theme's SURFACE, so
    /// the words came out the colour of the background they were meant to stand
    /// against, and the plate they sat on matched no rule at all and stayed
    /// near-black on every theme in the app.
    ///
    /// These have to match the shipped `LaunchScene.json` exactly enough to fall
    /// inside `colourTolerance`. Re-export the scene and a colour moves; miss it
    /// and the recolouring silently does nothing.
    static let navy: [Double] = [0.059, 0.169, 0.714]
    static let lettering: [Double] = [1, 1, 1]
    static let plate: [Double] = [0.1, 0.09, 0.11]
    /// How far an exported colour may sit from the value above and still be
    /// recognised. Exporters round, and a re-export nudges the last digit.
    static let colourTolerance: Double = 0.06

    static var rawJSON: Data? {
        guard let url = Bundle.module.url(forResource: "LaunchScene", withExtension: "json")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    public static var isAvailable: Bool { rawJSON != nil }

    /// The composition's own proportions, so the scene is laid out at the shape it
    /// was authored in rather than a hardcoded guess.
    public static var aspectRatio: CGFloat {
        guard let json = rawJSON,
              let doc = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let width = doc["w"] as? Double, let height = doc["h"] as? Double,
              width > 0, height > 0
        else { return 16.0 / 9.0 }
        return CGFloat(width / height)
    }

    /// The largest box of `aspectRatio` that fits inside `proposal` — an aspect
    /// FIT, so the scene is never wider or taller than the room it was offered.
    ///
    /// Pure, because "the launch animation overflows the screen" is a sizing
    /// arithmetic bug and arithmetic is exactly the thing a test can pin.
    /// A zero or non-finite dimension means "unspecified": the other one decides.
    static func fitted(aspectRatio: CGFloat, into proposal: CGSize) -> CGSize {
        guard aspectRatio > 0 else { return .zero }
        let offeredWidth = proposal.width.isFinite && proposal.width > 0 ? proposal.width : 0
        let offeredHeight = proposal.height.isFinite && proposal.height > 0 ? proposal.height : 0
        if offeredWidth <= 0, offeredHeight <= 0 { return .zero }
        if offeredWidth <= 0 {
            return CGSize(width: offeredHeight * aspectRatio, height: offeredHeight)
        }
        if offeredHeight <= 0 {
            return CGSize(width: offeredWidth, height: offeredWidth / aspectRatio)
        }
        if offeredWidth / offeredHeight > aspectRatio {
            return CGSize(width: offeredHeight * aspectRatio, height: offeredHeight)
        }
        return CGSize(width: offeredWidth, height: offeredWidth / aspectRatio)
    }

    /// How long the scene runs — used to schedule the hand-off even if the
    /// completion callback is missed (a backgrounded launch drops it).
    public static var duration: TimeInterval {
        guard let json = rawJSON,
              let doc = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let frames = doc["op"] as? Double, let rate = doc["fr"] as? Double, rate > 0
        else { return 2.6 }
        return frames / rate
    }

    /// The untouched scene — what the resource test checks.
    public static var animation: LottieAnimation? {
        guard let json = rawJSON else { return nil }
        return try? LottieAnimation.from(data: json)
    }

    /// The scene recoloured for a theme. Cached, because rebuilding it means
    /// re-encoding an embedded bitmap and the launch is the one place that can't
    /// afford to be slow.
    @MainActor private static var cache: [String: LottieAnimation] = [:]

    /// The shipped scene rewritten for a theme, as JSON.
    ///
    /// Kept separate from the parse so the rewrite can be checked on its own: the
    /// launch falls back to the baked artwork whenever anything downstream fails,
    /// and a fallback is indistinguishable — on screen and to a test that only
    /// asks whether an animation came back — from a theme being ignored.
    static func recolouredData(surface: ThemeColor, accent: ThemeColor) -> Data? {
        guard let json = rawJSON,
              var doc = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }

        // Everything the artwork DRAWS becomes the accent — the lettering, the
        // brand-blue decor, and the monogram bitmap — and the plate it is drawn
        // on becomes the surface, so the lockup melts into the themed background
        // exactly the way ClassMate's splash does.
        //
        // Lettering first: on a light theme the plate is about to become white,
        // and a plate recoloured before the lettering rule runs would be caught
        // by it and painted the accent as well.
        recolour(&doc, from: lettering, to: accent)
        recolour(&doc, from: navy, to: accent)
        recolour(&doc, from: plate, to: surface)
        tintEmbeddedImages(&doc, to: accent)

        return try? JSONSerialization.data(withJSONObject: doc)
    }

    /// The themed scene, or nil if it could not be built — no falling back.
    static func themedAnimation(surface: ThemeColor, accent: ThemeColor) -> LottieAnimation? {
        guard let data = recolouredData(surface: surface, accent: accent) else { return nil }
        return try? LottieAnimation.from(data: data)
    }

    /// Whether the theme-recoloured scene can actually be built and parsed. The
    /// test bar's way of asking the question the fallback hides.
    public static func canBuildThemedScene(surface: ThemeColor, accent: ThemeColor) -> Bool {
        themedAnimation(surface: surface, accent: accent) != nil
    }

    @MainActor
    public static func animation(surface: ThemeColor, accent: ThemeColor) -> LottieAnimation? {
        let key = "\(surface.hexString)-\(accent.hexString)"
        if let cached = cache[key] { return cached }
        guard let animation = themedAnimation(surface: surface, accent: accent) else {
            // A recolouring hiccup should cost the theme, never the launch.
            return Self.animation
        }
        cache[key] = animation
        return animation
    }

    // MARK: - Recolouring

    /// Rewrites every solid fill/stroke whose colour matches `from` (within a
    /// tolerance, because exported colours are rarely exact) to `to`.
    static func recolour(_ node: inout [String: Any], from: [Double], to: ThemeColor) {
        func matches(_ components: [Any]) -> Bool {
            guard components.count >= 3 else { return false }
            for index in 0..<3 {
                guard let value = components[index] as? Double,
                      abs(value - from[index]) <= colourTolerance else { return false }
            }
            return true
        }

        func walk(_ value: Any) -> Any {
            if var map = value as? [String: Any] {
                let type = map["ty"] as? String
                if type == "fl" || type == "st",
                   var colour = map["c"] as? [String: Any],
                   let components = colour["k"] as? [Any], matches(components) {
                    var replacement: [Any] = [to.red, to.green, to.blue]
                    if components.count > 3 { replacement.append(components[3]) }
                    colour["k"] = replacement
                    map["c"] = colour
                }
                for (key, child) in map where key != "c" {
                    map[key] = walk(child)
                }
                return map
            }
            if let list = value as? [Any] { return list.map(walk) }
            return value
        }

        node = (walk(node) as? [String: Any]) ?? node
    }

    /// Retints every base64-embedded raster asset to `to`, keeping its alpha — the
    /// mark's shape survives, only its colour changes. Best-effort per image: a
    /// decode failure leaves that asset exactly as shipped.
    static func tintEmbeddedImages(_ doc: inout [String: Any], to: ThemeColor) {
        guard var assets = doc["assets"] as? [Any] else { return }
        for index in assets.indices {
            guard var asset = assets[index] as? [String: Any],
                  let payload = asset["p"] as? String,
                  payload.hasPrefix("data:image"),
                  let comma = payload.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(payload[payload.index(after: comma)...])),
                  let image = UIImage(data: data),
                  let tinted = tint(image, with: to)?.pngData()
            else { continue }
            asset["p"] = "data:image/png;base64,\(tinted.base64EncodedString())"
            assets[index] = asset
        }
        doc["assets"] = assets
    }

    private static func tint(_ image: UIImage, with color: ThemeColor) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: image.size)
            // `.destinationIn` after filling keeps the source alpha and replaces
            // the colour — the same result as Flutter's srcIn.
            UIColor(
                red: color.red, green: color.green, blue: color.blue, alpha: 1
            ).setFill()
            context.fill(rect)
            image.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }
    }
}

/// Plays a `LottieAnimation` once and calls `onFinished`.
///
/// It reports its own size (`sizeThatFits`) rather than leaving SwiftUI to infer
/// one from Auto Layout: a `LottieAnimationView`'s intrinsic size is the
/// composition's, 1280×720 here, and a representable that never answers the
/// proposal is laid out at that size whatever it was offered.
public struct LaunchSceneView: UIViewRepresentable {
    let animation: LottieAnimation
    let onFinished: () -> Void

    public init(animation: LottieAnimation, onFinished: @escaping () -> Void) {
        self.animation = animation
        self.onFinished = onFinished
    }

    public func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView(animation: animation)
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .pauseAndRestore
        view.loopMode = .playOnce
        view.backgroundColor = .clear
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The composition is authored at 1280×720, and that is the view's
        // intrinsic size. At the DEFAULT compression resistance UIKit refuses to
        // lay it out any narrower than 1280 points — so on a phone the scene ran
        // off both edges of the screen instead of fitting inside it.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.play { _ in
            // Fires with `false` when playback was interrupted (backgrounded
            // mid-launch). Either way the app has to move on — never strand the
            // user on a splash screen.
            onFinished()
        }
        return view
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: LottieAnimationView, context: Context
    ) -> CGSize? {
        LaunchScene.fitted(
            aspectRatio: LaunchScene.aspectRatio,
            into: CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        )
    }

    /// Swaps in a scene that has been rebuilt for a different theme.
    ///
    /// `makeUIView` runs once, so an empty update meant the very first animation
    /// SwiftUI happened to resolve was the one that played for the whole launch —
    /// and if the theme settled a frame later (a pinned dark mode arriving with
    /// the first layout), the recoloured scene never reached the screen. From the
    /// outside that is a launch that ignores the theme.
    public func updateUIView(_ uiView: LottieAnimationView, context: Context) {
        guard uiView.animation !== animation else { return }
        let progress = uiView.currentProgress
        uiView.animation = animation
        uiView.currentProgress = progress
        uiView.play(fromProgress: progress, toProgress: 1, loopMode: .playOnce) { _ in
            onFinished()
        }
    }
}
