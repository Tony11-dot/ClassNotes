import Testing
@testable import ClassMateTheme

/// The contract behind putting `glassTint` into `.glassEffect(.regular.tint(...))`:
/// at maximum transparency the glass contributes ONLY the tint over whatever is
/// behind it, so text on glass must stay readable against `glassTint` composited
/// over both possible backdrops (chrome surface and paper).
@Suite("Glass contrast at maximum transparency")
struct GlassContrastTests {
    /// WCAG AA for normal text. Solarized ships ClassMate's own low-contrast
    /// text color (#93A1A1 on #002B36 ≈ 4.1:1 in ClassMate itself) — we pin it
    /// at AA-large rather than break fidelity with the source palette.
    private func minimumInkContrast(for preset: ThemePreset) -> Double {
        preset == .solarized ? 4.0 : 4.5
    }

    @Test("Ink stays readable on tinted glass over surface and paper", arguments: ThemePreset.allCases)
    func inkOnGlass(preset: ThemePreset) {
        let spec = preset.spec
        for backdrop in [spec.surface, spec.paper] {
            let glass = spec.glassTint.composited(over: backdrop)
            let contrast = spec.ink.contrastRatio(against: glass)
            #expect(
                contrast >= minimumInkContrast(for: preset),
                "\(preset.rawValue): ink on glass-over-\(backdrop.hexString) is \(contrast)"
            )
        }
    }

    @Test("Secondary ink meets AA-large on tinted glass", arguments: ThemePreset.allCases)
    func secondaryInkOnGlass(preset: ThemePreset) {
        let spec = preset.spec
        let glass = spec.glassTint.composited(over: spec.surface)
        #expect(spec.inkSecondary.contrastRatio(against: glass) >= 3.0)
    }

    @Test("Accent is distinguishable against surface", arguments: ThemePreset.allCases)
    func accentOnSurface(preset: ThemePreset) {
        let spec = preset.spec
        #expect(spec.accent.contrastRatio(against: spec.surface) >= 3.0)
    }

    @Test("Ink on paper meets AA in every paper tone", arguments: ThemePreset.allCases)
    func inkOnPaper(preset: ThemePreset) {
        let spec = preset.spec
        for tone in PaperTone.allCases {
            let paper = tone.apply(to: spec.paper)
            let contrast = spec.ink.contrastRatio(against: paper)
            #expect(
                contrast >= minimumInkContrast(for: preset),
                "\(preset.rawValue)/\(tone.rawValue): ink on paper is \(contrast)"
            )
        }
    }
}
