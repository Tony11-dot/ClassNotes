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
/// ClassMate does it (`splash_screen.dart`): the baked white canvas becomes the
/// theme's surface so the animation melts into the background, and the navy mark
/// becomes the theme's accent. The CN monogram is an embedded PNG inside the
/// composition, which vector recolouring can't reach, so its pixels are retinted
/// separately with the alpha preserved. On the plain light theme this is close to
/// identity, so the original blue splash survives.
public enum LaunchScene {
    /// The two colours baked into the artwork: the navy mark and the white canvas.
    static let navy: [Double] = [0.047, 0.098, 0.576]
    static let white: [Double] = [1, 1, 1]

    static var rawJSON: Data? {
        guard let url = Bundle.module.url(forResource: "LaunchScene", withExtension: "json")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    public static var isAvailable: Bool { rawJSON != nil }

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

    @MainActor
    public static func animation(surface: ThemeColor, accent: ThemeColor) -> LottieAnimation? {
        let key = "\(surface.hexString)-\(accent.hexString)"
        if let cached = cache[key] { return cached }
        guard let json = rawJSON,
              var doc = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }

        recolour(&doc, from: white, to: surface)
        recolour(&doc, from: navy, to: accent)
        tintEmbeddedImages(&doc, to: accent)

        guard let data = try? JSONSerialization.data(withJSONObject: doc),
              let animation = try? LottieAnimation.from(data: data) else {
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
                      abs(value - from[index]) <= 0.03 else { return false }
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
        view.play { _ in
            // Fires with `false` when playback was interrupted (backgrounded
            // mid-launch). Either way the app has to move on — never strand the
            // user on a splash screen.
            onFinished()
        }
        return view
    }

    public func updateUIView(_ uiView: LottieAnimationView, context: Context) {}
}
