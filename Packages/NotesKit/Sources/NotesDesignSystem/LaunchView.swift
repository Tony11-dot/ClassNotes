import ClassMateTheme
import SwiftUI

/// The launch animation, rebuilt natively to match ClassMate's `CmSplashScreen`:
/// white/paper background, the CM mark fades + scales in (easeOutBack), then the
/// "ClassMate Notes" wordmark reveals with a blinking cursor, then it hands off.
public struct LaunchView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinished: () -> Void

    @State private var markIn = false
    @State private var textProgress = 0
    @State private var showCursor = true
    @State private var faded = false

    private let fullText = "ClassMate Notes"

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    private var revealed: String {
        String(fullText.prefix(textProgress))
    }

    public var body: some View {
        ZStack {
            theme.paper.color.ignoresSafeArea()
            HStack(spacing: 12) {
                BrandMark(size: 76)
                    .scaleEffect(markIn ? 1 : 0.85)
                    .opacity(markIn ? 1 : 0)
                HStack(spacing: 1) {
                    Text(revealed)
                        .font(CMFonts.font(size: 30, weight: .bold))
                        .foregroundStyle(theme.accent.color)
                    if textProgress < fullText.count || showCursor {
                        Rectangle()
                            .fill(theme.accent.color)
                            .frame(width: 3, height: 30)
                            .opacity(showCursor ? 1 : 0)
                    }
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
            textProgress = fullText.count
            try? await Task.sleep(for: .milliseconds(500))
            onFinished()
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { markIn = true }
        try? await Task.sleep(for: .milliseconds(420))
        for index in 0...fullText.count {
            textProgress = index
            try? await Task.sleep(for: .milliseconds(45))
        }
        // Cursor blink a couple of times.
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.easeInOut(duration: 0.1)) { showCursor.toggle() }
        }
        withAnimation(.easeIn(duration: 0.35)) { faded = true }
        try? await Task.sleep(for: .milliseconds(360))
        onFinished()
    }
}
