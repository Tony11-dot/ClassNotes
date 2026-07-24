import Foundation
import Testing
@testable import ClassMateTheme

@Suite("ThemeColor")
struct ThemeColorTests {
    @Test("Hex parsing accepts #RRGGBB, RRGGBB and #RRGGBBAA")
    func hexParsing() throws {
        let opaque = try #require(ThemeColor(hex: "#417262"))
        #expect(opaque.hexString == "#417262")
        #expect(ThemeColor(hex: "417262") == opaque)

        let translucent = try #require(ThemeColor(hex: "#41726280"))
        #expect(abs(translucent.alpha - 128.0 / 255.0) < 0.0001)
        #expect(translucent.hexString == "#41726280")

        #expect(ThemeColor(hex: "#41") == nil)
        #expect(ThemeColor(hex: "not-a-color") == nil)
    }

    @Test("Codable round-trips through hex strings")
    func codableRoundTrip() throws {
        let colors = [
            ThemeColor(hex: "#88511E")!,
            ThemeColor(hex: "#88511E33")!,
            ThemeColor(red: 1, green: 1, blue: 1)
        ]
        let data = try JSONEncoder().encode(colors)
        let decoded = try JSONDecoder().decode([ThemeColor].self, from: data)
        #expect(decoded == colors)
    }

    @Test("Compositing a fully opaque color replaces the background")
    func compositeOpaque() {
        let red = ThemeColor(red: 1, green: 0, blue: 0)
        let blue = ThemeColor(red: 0, green: 0, blue: 1)
        #expect(red.composited(over: blue) == red)
    }

    @Test("Compositing at zero alpha keeps the background")
    func compositeTransparent() {
        let clearRed = ThemeColor(red: 1, green: 0, blue: 0, alpha: 0)
        let blue = ThemeColor(red: 0, green: 0, blue: 1)
        #expect(clearRed.composited(over: blue) == blue)
    }

    @Test("Contrast of black on white is 21:1")
    func contrastExtremes() {
        let black = ThemeColor(red: 0, green: 0, blue: 0)
        let white = ThemeColor(red: 1, green: 1, blue: 1)
        #expect(abs(black.contrastRatio(against: white) - 21.0) < 0.01)
        #expect(abs(white.contrastRatio(against: black) - 21.0) < 0.01)
    }

    @Test("ThemeSpec JSON export/import round-trips")
    func specRoundTrip() throws {
        var custom = ThemePreset.wine.spec
        custom.id = "custom-9F0A"
        custom.displayName = "My Wine"
        custom.paper = ThemeColor(hex: "#221018")!
        let data = try ThemeJSON.encode([custom])
        let decoded = try ThemeJSON.decode(data)
        #expect(decoded == [custom])
    }
}
