import ClassMateTheme
import SwiftUI

/// The launch animation, rebuilt to match ClassMate's splash (`_LottieSplash`)
/// as closely as native code allows — background, decor, placement, and motion:
///
/// - Background is the current theme's `surface` (ClassMate:
///   `Scaffold(backgroundColor: scheme.surface)`).
/// - Behind the logo, the drifting study-symbol `AmbientBackground` fades in
///   over ~1.1s (ClassMate layers `AmbientSymbols` with a 1100ms easeOutCubic
///   opacity tween).
/// - The logo is CENTERED (ClassMate: `Center(child: Lottie(fit: contain))`),
///   sized small so it "melts into" the themed field rather than filling it.
/// - Motion mirrors the reference `Scene.json` (120f @ 60fps): the CN mark pops
///   in (scale 0→1), then the "ClassNotes" wordmark slides up + fades in beside
///   it, holds, and hands off.
///
/// Everything is tinted to the theme `accent` — ClassMate's navy→primary
/// recolour — so the whole scene tracks the current theme.
public struct LaunchView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinished: () -> Void

    @State private var decorIn = false
    @State private var markIn = false
    @State private var showWord = false
    @State private var faded = false
    /// The scene reports completion AND a timeout arms behind it, so the hand-off
    /// has to be idempotent — routing twice would rebuild the whole app tree.
    @State private var finished = false

    // Small, crisp lockup (smaller = less raster upscaling = sharper wordmark),
    // in the artwork's proportions (mark : wordmark-cap-height : gap).
    private let markSize: CGFloat = 64
    private let wordHeight: CGFloat = 38

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    public var body: some View {
        if let scene = LaunchScene.animation(surface: theme.surface, accent: theme.accent) {
            // The designed scene itself, recoloured to the theme the way ClassMate
            // recolours its own splash. Everything below is a fallback for when it
            // isn't bundled.
            ZStack {
                theme.surface.color.ignoresSafeArea()
                LaunchSceneView(animation: scene, onFinished: finishOnce)
                    // The scene is authored 1280×720; letting it fill the screen
                    // makes the lockup enormous on an iPad. Capped so it sits as a
                    // mark on a themed field rather than as a poster.
                    .frame(maxWidth: 460, maxHeight: 260)
            }
            .task {
                CMFonts.registerIfNeeded()
                // A safety net: if playback never reports completion (launched
                // into the background, animations disabled), hand off anyway.
                try? await Task.sleep(for: .seconds(LaunchScene.duration + 1.2))
                finishOnce()
            }
        } else if let videoURL = LaunchMedia.videoURL {
            // Your bundled launch clip plays once, then hands off. Falls back to
            // the native animation below if no video has been added yet.
            ZStack {
                theme.surface.color.ignoresSafeArea()
                LaunchVideoView(url: videoURL, onFinished: onFinished)
                    .ignoresSafeArea()
            }
            .task { CMFonts.registerIfNeeded() }
        } else {
            nativeBody
        }
    }

    /// Hands off exactly once, whichever signal gets there first.
    private func finishOnce() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    private var nativeBody: some View {
        ZStack {
            // Solid themed base first, so there is never a flash before the
            // ambient layer fades in (ClassMate: same surface end-to-end).
            theme.surface.color.ignoresSafeArea()
            AmbientBackground(seed: 3)
                .opacity(decorIn ? 1 : 0)
            HStack(spacing: 14) {
                // The CN mark pops in (Scene ref: scale 0→100%, t12–t48).
                BrandMark(size: markSize)
                    .scaleEffect(markIn ? 1 : 0.35)
                    .opacity(markIn ? 1 : 0)
                // The wordmark slides up + fades in beside it (Scene ref:
                // wordmark group y 73.6→0 + opacity 0→100, t60–t78). Its
                // insertion also grows the HStack, recentering the mark
                // leftward — the reference's "mark settles left" motion.
                if showWord {
                    BrandWordmark(height: wordHeight)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .opacity(faded ? 0 : 1)
        }
        .task { await run() }
    }

    private func run() async {
        CMFonts.registerIfNeeded()
        if reduceMotion {
            decorIn = true
            markIn = true
            showWord = true
            try? await Task.sleep(for: .milliseconds(700))
            onFinished()
            return
        }
        // 0) Ambient symbols fade in (ClassMate: 1100ms easeOutCubic).
        withAnimation(.easeOut(duration: 1.1)) { decorIn = true }
        // 1) Mark pops in.
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { markIn = true }
        // 2) Wordmark reveals; HStack recenters.
        try? await Task.sleep(for: .milliseconds(780))
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { showWord = true }
        // 3) Hold, then hand off (~2s total, matching the reference).
        try? await Task.sleep(for: .milliseconds(760))
        withAnimation(.easeIn(duration: 0.35)) { faded = true }
        try? await Task.sleep(for: .milliseconds(360))
        onFinished()
    }
}
