import ClassMateTheme
import SwiftUI

/// NOVA's gradient orb — accent→muted with a white sheen and hairline ring,
/// centered sparkle. Mirrors ClassMate's `NovaAvatar`.
public struct NovaAvatar: View {
    @Environment(\.theme) private var theme
    let size: CGFloat
    var animated: Bool

    public init(size: CGFloat = 28, animated: Bool = false) {
        self.size = size
        self.animated = animated
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [theme.accent.color, theme.accentMuted.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RadialGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.05), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size
                    )
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
                .shadow(color: theme.accent.color.opacity(0.35), radius: size * 0.25, y: size * 0.08)

            Image(systemName: "sparkles")
                .font(.dsSystem(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: animated ? .repeating : .default, value: animated)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("NOVA")
    }
}

/// Three bouncing dots for NOVA's "thinking" state.
public struct TypingDots: View {
    @Environment(\.theme) private var theme
    @State private var phase = 0.0

    public init() {}

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(theme.inkSecondary.color)
                        .frame(width: 6, height: 6)
                        .offset(y: -3 * sin(t * 4 + Double(index) * 0.6))
                }
            }
        }
        .accessibilityLabel("NOVA is thinking")
    }
}
