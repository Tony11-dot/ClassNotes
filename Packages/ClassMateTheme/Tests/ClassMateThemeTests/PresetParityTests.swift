import Testing
@testable import ClassMateTheme

@Suite("Preset parity with the ClassMate fixture")
struct PresetParityTests {
    @Test("All 19 presets exist, in family order")
    func presetCount() {
        #expect(ThemePreset.allCases.count == 19)
        #expect(ThemePreset.lightFamily.count == 9)
        #expect(ThemePreset.darkFamily.count == 10)
    }

    @Test("Swift presets match themes.json exactly")
    func fixtureParity() throws {
        let fixture = try ThemeFixture.load()
        #expect(fixture.count == ThemePreset.allCases.count)

        for entry in fixture {
            let preset = try #require(ThemePreset(rawValue: entry.id))
            let spec = preset.spec
            #expect(spec.displayName == entry.displayName)
            #expect(spec.isDark == entry.isDark)
            #expect(spec.accent.hexString == entry.accent)
            #expect(spec.accentMuted.hexString == entry.accentMuted)
            #expect(spec.surface.hexString == entry.surface)
            #expect(spec.surfaceRaised.hexString == entry.surfaceRaised)
            #expect(spec.paper.hexString == entry.paper)
            #expect(spec.ink.hexString == entry.ink)
            #expect(spec.inkSecondary.hexString == entry.inkSecondary)
            #expect(spec.separator.hexString == entry.separator)
        }
    }

    @Test("glassTint is the accent at the standard glass alpha")
    func glassTintDerivation() {
        for preset in ThemePreset.allCases {
            let spec = preset.spec
            #expect(spec.glassTint == spec.accent.withAlpha(ThemePreset.glassTintAlpha))
        }
    }

    @Test("Cover palette holds every preset accent, own accent first")
    func coverPalette() {
        for preset in ThemePreset.allCases {
            let palette = preset.spec.coverPalette
            #expect(palette.count == 19)
            #expect(palette.first == preset.accent)
            #expect(Set(palette.map(\.hexString)) == Set(ThemePreset.allCases.map(\.accent.hexString)))
        }
    }

    @Test("Display names keep ClassMate naming, including Rosé")
    func displayNames() {
        #expect(ThemePreset.rose.displayName == "Rosé")
        #expect(ThemePreset.solarized.displayName == "Solarized")
        #expect(ThemePreset.light.displayName == "Light")
    }

    @Test("Nearest preset of a preset's own spec is itself")
    func nearestIdentity() {
        for preset in ThemePreset.allCases {
            #expect(ThemePreset.nearest(to: preset.spec) == preset)
        }
    }

    @Test("Nearest preset of a slightly perturbed custom spec stays stable")
    func nearestPerturbed() {
        var spec = ThemePreset.matcha.spec
        spec.id = "custom-test"
        spec.accent = ThemeColor(
            red: spec.accent.red + 0.02,
            green: spec.accent.green - 0.02,
            blue: spec.accent.blue
        )
        #expect(ThemePreset.nearest(to: spec) == .matcha)
    }
}
