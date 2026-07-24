import ClassMateTheme
import SwiftUI

extension EnvironmentValues {
    /// The active theme, injected once at the routing root. Every themed view
    /// reads this — never a raw color.
    @Entry public var theme: ThemeSpec = ThemePreset.light.spec

    /// Warm/neutral/cool paper cast, independent of the theme.
    @Entry public var paperTone: PaperTone = .neutral
}

extension ThemeSpec {
    /// The page background with the paper tone applied.
    public func paperColor(tone: PaperTone) -> ThemeColor {
        tone.apply(to: paper)
    }

    /// Legible label color for content laid over an arbitrary token (e.g.
    /// titles on notebook covers).
    public func contrastingInk(on background: ThemeColor) -> ThemeColor {
        let white = ThemeColor(red: 1, green: 1, blue: 1)
        let black = ThemeColor(red: 0.08, green: 0.09, blue: 0.10)
        return background.contrastRatio(against: white) >= background.contrastRatio(against: black)
            ? white
            : black
    }
}
