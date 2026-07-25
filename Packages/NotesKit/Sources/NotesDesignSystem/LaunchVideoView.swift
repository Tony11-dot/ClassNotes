import AVFoundation
import SwiftUI

/// Plays a bundled launch-animation video (your ClassNotes intro clip) once,
/// full-bleed, then calls `onFinished`. If no such file is bundled, callers
/// fall back to the native `LaunchView` animation — so the app always launches
/// cleanly whether or not the video has been added yet.
///
/// WHERE TO PUT YOUR VIDEO
/// ───────────────────────
/// Drop a file named `LaunchAnimation.mp4` (or `.mov`) into the app target so
/// it ships in `Bundle.main`. Easiest path in Xcode:
///   1. Put the file at `App/Resources/LaunchAnimation.mp4`.
///   2. Drag it into the Xcode project navigator, ticking the ClassNotes
///      target under "Add to targets".
/// That's it — `LaunchView` auto-detects and plays it. Transparent background
/// looks best on `theme.paper`; a square or portrait clip is ideal.
public enum LaunchMedia {
    /// The bundled launch clip, if one has been added. Checked names in order.
    public static var videoURL: URL? {
        for name in ["LaunchAnimation"] {
            for ext in ["mov", "mp4", "m4v"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                    return url
                }
            }
        }
        return nil
    }

    public static var hasVideo: Bool { videoURL != nil }
}

/// A minimal, looping-free AVPlayer view that reports completion.
public struct LaunchVideoView: UIViewRepresentable {
    let url: URL
    let onFinished: () -> Void

    public init(url: URL, onFinished: @escaping () -> Void) {
        self.url = url
        self.onFinished = onFinished
    }

    public func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(url: url, onFinished: onFinished)
        return view
    }

    public func updateUIView(_ uiView: PlayerContainerView, context: Context) {}

    /// UIView that owns the player layer so it resizes with the view and cleans
    /// up its end-of-playback observer.
    public final class PlayerContainerView: UIView {
        private var player: AVPlayer?
        private var onFinished: (() -> Void)?
        private let playerLayer = AVPlayerLayer()

        public override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }

        func configure(url: URL, onFinished: @escaping () -> Void) {
            self.onFinished = onFinished
            let player = AVPlayer(url: url)
            player.isMuted = true
            self.player = player
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            if playerLayer.superlayer == nil { layer.addSublayer(playerLayer) }
            backgroundColor = .clear
            // Selector-based observer so `removeObserver(self)` in deinit is
            // Sendable-safe (a block token isn't, under Swift 6 strict mode).
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playedToEnd),
                name: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem
            )
            player.play()
        }

        @objc private func playedToEnd() {
            onFinished?()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
