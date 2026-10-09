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
