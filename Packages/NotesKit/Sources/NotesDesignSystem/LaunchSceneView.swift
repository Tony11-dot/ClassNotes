import ClassMateTheme
import Lottie
import SwiftUI

/// The designed launch animation — the Lottie scene exported from Jitter — played
/// once, then handed off.
///
/// The app used to rebuild this scene by hand in SwiftUI, which meant the launch
/// was a *likeness* of the artwork that drifted every time the artwork changed.
/// Shipping the `.json` itself makes the animation the source of truth: replacing
/// `Resources/LaunchScene.json` replaces the launch.
///
/// The scene plays as authored (the CN mark is a raster layer, so it keeps
/// ClassNotes navy rather than following the theme accent); it sits on the theme's
/// own `surface`, so the field around it still tracks the theme.
public enum LaunchScene {
    /// The bundled scene, parsed once. `nil` only if the resource is missing or
    /// malformed — callers fall back to the native animation.
    public static let animation: LottieAnimation? = LottieAnimation.named(
        "LaunchScene", bundle: .module
    )

    public static var isAvailable: Bool { animation != nil }

    /// How long the scene runs, in seconds — used to schedule the hand-off even if
    /// the completion callback is missed (a backgrounded launch drops it).
    public static var duration: TimeInterval { animation?.duration ?? 2.6 }
}

/// Plays `LaunchScene.animation` once and calls `onFinished`.
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
        // The scene is authored 1280×720; letting it size itself would stretch the
        // launch screen to that aspect instead of centering in it.
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
