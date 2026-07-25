import ClassMateTheme
import SwiftUI

/// The launch animation, rebuilt natively to match ClassMate's splash and the
/// provided Jitter reference (`Scene.json`): on the current theme's `surface`
/// background, the CN mark pops in (scale 0→1 with a slight overshoot), then the
/// "ClassNotes" wordmark slides up + fades in beside it, holds, and hands off
/// (~2s total, mirroring the reference's 120f @ 60fps timeline). Everything is
/// tinted to the theme `accent` — ClassMate's navy→primary recolour — so the
/// whole animation, background included, tracks the current theme.
public struct LaunchView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinished: () -> Void

    @State private var markIn = false
    @State private var showWord = false
    @State private var faded = false

    // Matched to the launch preview: mark frame 104pt, wordmark cap-height 63pt,
    // gap 20pt — the same proportions as the ClassNotes lockup artwork.
    private let markSize: CGFloat = 104
    private let wordHeight: CGFloat = 63

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    public var body: some View {
        if let videoURL = LaunchMedia.videoURL {
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

    private var nativeBody: some View {
        ZStack {
            // Launch background tracks the current theme's `surface`, exactly
            // like ClassMate's splash (`Scaffold(backgroundColor: scheme.surface)`).
            theme.surface.color.ignoresSafeArea()
            HStack(spacing: 20) {
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
            markIn = true
            showWord = true
            try? await Task.sleep(for: .milliseconds(700))
            onFinished()
            return
        }
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
