import ClassMateTheme
import SwiftUI

/// The soft wash + drifting study symbols behind the login and NOVA surfaces,
/// mirroring ClassMate's ambient background. Honors Reduce Motion (freezes).
public struct AmbientBackground: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let seed: Int
    let opacity: Double

    public init(seed: Int = 5, opacity: Double = 0.9) {
        self.seed = seed
        self.opacity = opacity
    }

    private static let glyphs = ["∫", "π", "√", "∑", "♪", "＋", "×", "★", "○", "λ", "%", "∞"]

    public var body: some View {
        let wash = theme.accent.withAlpha(theme.isDark ? 0.16 : 0.07).composited(over: theme.surface)
        ZStack {
            wash.color
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    var rng = SplitMix64(seed: UInt64(seed) &* 0x9E3779B9)
                    let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    for index in 0..<16 {
                        let baseX = rng.nextUnit() * size.width
                        let baseY = rng.nextUnit() * size.height
                        let drift = CGFloat(sin(t * 0.15 + Double(index))) * 14
                        let glyph = Self.glyphs[index % Self.glyphs.count]
                        let fontSize = 16 + rng.nextUnit() * 26
                        let alpha = (0.05 + rng.nextUnit() * 0.10) * opacity
                        let resolved = context.resolve(
                            Text(glyph).font(.dsSystem(size: fontSize, weight: .semibold))
                        )
                        context.opacity = alpha
                        context.draw(
                            resolved,
                            at: CGPoint(x: baseX, y: baseY + drift),
                            anchor: .center
                        )
                    }
                }
            }
            .foregroundStyle(theme.accent.color)
        }
        .ignoresSafeArea()
    }
}

/// Tiny deterministic RNG so the ambient layout is stable per seed (no
/// `Math.random`-style flicker between frames).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}
