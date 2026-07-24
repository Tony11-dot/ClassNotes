import ClassMateTheme
import PencilKit
import Testing
import UIKit
@testable import NotesEditor

@MainActor
@Suite("Editor tool state")
struct ToolStateTests {
    @Test("Tools map to the right PencilKit tools with themed defaults")
    func pkToolMapping() throws {
        let state = ToolState()
        let theme = ThemePreset.matcha.spec

        let pen = try #require(state.pkTool(theme: theme) as? PKInkingTool)
        #expect(pen.inkType == .pen)
        #expect(abs(pen.width - state.penWidth) < 0.001)

        state.select(.highlighter)
        let marker = try #require(state.pkTool(theme: theme) as? PKInkingTool)
        #expect(marker.inkType == .marker)

        state.select(.eraser)
        #expect(state.pkTool(theme: theme) is PKEraserTool)

        state.select(.lasso)
        #expect(state.pkTool(theme: theme) is PKLassoTool)
    }

    @Test("Default ink colors follow the theme until overridden")
    func themedDefaults() {
        let state = ToolState()
        let matcha = ThemePreset.matcha.spec
        let nord = ThemePreset.nord.spec

        #expect(state.currentColor(theme: matcha) == matcha.ink)
        #expect(state.currentColor(theme: nord) == nord.ink)

        state.setCurrentColor(matcha.accent)
        #expect(state.currentColor(theme: nord) == matcha.accent)
    }

    @Test("Ink palette is themed, deduped and leads with ink + accent", arguments: ThemePreset.allCases)
    func inkPalette(preset: ThemePreset) {
        let state = ToolState()
        let spec = preset.spec
        let palette = state.inkPalette(theme: spec)
        #expect(palette.count <= 10)
        #expect(palette[0] == spec.ink)
        #expect(palette[1] == spec.accent)
        #expect(Set(palette.map(\.hexString)).count == palette.count)
    }

    @Test("Pencil double-tap toggles eraser and honors switch-previous")
    func doubleTap() {
        let state = ToolState()
        #expect(state.tool == .pen)

        state.handlePencilTap(preferred: .switchEraser)
        #expect(state.tool == .eraser)
        state.handlePencilTap(preferred: .switchEraser)
        #expect(state.tool == .pen)

        state.select(.highlighter)
        state.select(.pen)
        state.handlePencilTap(preferred: .switchPrevious)
        #expect(state.tool == .highlighter)
    }

    @Test("Pencil squeeze cycles pen → highlighter → eraser → lasso")
    func squeeze() {
        let state = ToolState()
        let expected: [ToolState.Tool] = [.highlighter, .eraser, .lasso, .pen]
        for tool in expected {
            state.handlePencilSqueeze()
            #expect(state.tool == tool)
        }
    }

    @Test("Per-tool width editing routes to the active tool")
    func widths() {
        let state = ToolState()
        state.currentWidth = 5
        #expect(state.penWidth == 5)

        state.select(.highlighter)
        state.currentWidth = 22
        #expect(state.highlighterWidth == 22)
        #expect(state.penWidth == 5)
    }
}
