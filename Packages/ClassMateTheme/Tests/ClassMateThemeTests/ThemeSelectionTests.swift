import Foundation
import Testing
@testable import ClassMateTheme

@Suite("ThemeSelection and PaperTone")
struct ThemeSelectionTests {
    @Test("Selection raw values round-trip")
    func rawValueRoundTrip() throws {
        let uuid = UUID()
        let selections: [ThemeSelection] = [.system, .preset(.nord), .custom(uuid)]
        for selection in selections {
            #expect(ThemeSelection(rawValue: selection.rawValue) == selection)
        }
        #expect(ThemeSelection(rawValue: "preset:nope") == nil)
        #expect(ThemeSelection(rawValue: "custom:not-a-uuid") == nil)
        #expect(ThemeSelection(rawValue: "") == nil)
    }

    @Test("System selection resolves to plain Light/Dark by OS appearance")
    func systemResolution() {
        #expect(ThemeSelection.systemSpec(prefersDark: false).id == "light")
        #expect(ThemeSelection.systemSpec(prefersDark: true).id == "dark")
    }

    @Test("Neutral paper tone is identity; warm/cool shift is subtle")
    func paperTones() {
        for preset in ThemePreset.allCases {
            let paper = preset.spec.paper
            #expect(PaperTone.neutral.apply(to: paper) == paper)
            for tone in [PaperTone.warm, .cool] {
                let toned = tone.apply(to: paper)
                #expect(toned != paper)
                #expect(toned.distance(to: paper) < 0.1, "\(preset.rawValue)/\(tone.rawValue) drifted too far")
            }
        }
    }

    @Test("Warm warms and cool cools the red/blue balance")
    func paperToneDirection() {
        let paper = ThemePreset.light.spec.paper
        let warm = PaperTone.warm.apply(to: paper)
        let cool = PaperTone.cool.apply(to: paper)
        #expect(warm.red - warm.blue > cool.red - cool.blue)
    }
}
