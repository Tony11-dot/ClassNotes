import ClassMateTheme
import NotesModels
import PencilKit
import Testing
import UIKit
@testable import NotesEditor

@MainActor
@Suite("Editor tool state")
struct ToolStateTests {
    @Test("Every tray instrument maps to its own PencilKit ink at its tuned width")
    func penTrayMapping() throws {
        let state = ToolState()
        let theme = ThemePreset.matcha.spec

        for preset in PenLibrary.all {
            state.selectPen(preset)
            let tool = try #require(state.pkTool(theme: theme) as? PKInkingTool)
            #expect(tool.inkType == preset.ink.pkInkType)
            #expect(abs(tool.width - state.settings(for: preset).effectiveWidth) < 0.001)
        }
    }

    @Test("The tray is a couple of genuinely different instruments, not a wall of tuning")
    func trayCoversInkFamilies() {
        let inks = Set(PenLibrary.all.map(\.ink))
        // `.monoline` and `.watercolor` are deliberately NOT offered: on real
        // hardware `.monoline` was the one ink family that could lose a
        // hold-to-snap shape outright, traced to PencilKit's own renderer
        // rather than anything fixable in this app — see the doc comment on
        // `PenLibrary.all`.
        #expect(!inks.contains(.monoline))
        #expect(inks.contains(.pen))
        #expect(inks.contains(.marker))
        #expect(Set(PenLibrary.all.map(\.id)).count == PenLibrary.all.count)
    }

    @Test("Eraser modes map to the right PencilKit eraser, and tape-only never erases ink")
    func eraserModes() throws {
        let state = ToolState()
        let theme = ThemePreset.nord.spec
        state.select(.eraser)

        state.eraserMode = .pixel
        #expect(state.pkTool(theme: theme) is PKEraserTool)
        state.eraserMode = .stroke
        #expect(state.pkTool(theme: theme) is PKEraserTool)

        // Tape lives above the ink as page elements, so the canvas tool must be
        // inert in this mode — otherwise a tap would eat the notes underneath.
        state.eraserMode = .tapeOnly
        let inert = try #require(state.pkTool(theme: theme) as? PKInkingTool)
        #expect(inert.color.cgColor.alpha == 0)
    }

    @Test("Tape, text and move modes hand the pencil to the overlays")
    func nonDrawingModes() {
        let state = ToolState()
        #expect(state.isDrawingEnabled)
        for tool in [ToolState.Tool.tape, .text, .hand] {
            state.select(tool)
            #expect(!state.isDrawingEnabled)
        }
        state.select(.eraser)
        #expect(state.isDrawingEnabled)
    }

    @Test("Tapping the pen already in hand reports it, so the rail opens its settings")
    func secondTapOpensSettings() {
        let state = ToolState()
        let ballpoint = PenLibrary.ballpoint
        let highlighter = PenLibrary.preset(id: "highlighter")

        #expect(state.selectPen(ballpoint) == true, "ballpoint is selected by default")
        #expect(state.selectPen(highlighter) == false, "first tap only picks the highlighter up")
        #expect(state.selectPen(highlighter) == true, "second tap asks for its settings")
    }

    @Test("Each instrument keeps its own tuning")
    func perPenTuning() {
        let state = ToolState()
        let ballpoint = PenLibrary.ballpoint
        let highlighter = PenLibrary.preset(id: "highlighter")

        state.selectPen(ballpoint)
        state.currentWidth = 4
        state.selectPen(highlighter)
        state.currentWidth = 14

        #expect(state.settings(for: ballpoint).thickness == 4)
        #expect(state.settings(for: highlighter).thickness == 14)

        state.resetPen(highlighter)
        #expect(state.settings(for: highlighter).thickness == highlighter.defaults.thickness)
        #expect(state.settings(for: ballpoint).thickness == 4, "resetting one pen leaves the others alone")
    }

    @Test("Tuning is clamped into each instrument's own range")
    func tuningClamped() {
        let state = ToolState()
        let ballpoint = PenLibrary.ballpoint
        state.setSettings(PenSettings(thickness: 900, concentration: 0), for: ballpoint)
        let settings = state.settings(for: ballpoint)
        #expect(settings.thickness == ballpoint.widthRange.upperBound)
        #expect(settings.concentration >= 0.05)
    }

    @Test("Concentration becomes the ink's alpha")
    func concentrationIsOpacity() throws {
        let state = ToolState()
        let theme = ThemePreset.matcha.spec
        var settings = state.penSettings
        settings.concentration = 0.4
        state.penSettings = settings

        let tool = try #require(state.pkTool(theme: theme) as? PKInkingTool)
        #expect(abs(tool.color.cgColor.alpha - 0.4) < 0.02)
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

    @Test("Tape colour falls back to the theme until the user picks one")
    func tapeColor() {
        let state = ToolState()
        let spec = ThemePreset.rose.spec
        #expect(state.tapeColor(theme: spec) == spec.accentMuted)
        state.tapeColorHex = spec.accent.hexString
        #expect(state.tapeColor(theme: spec) == spec.accent)
    }

    @Test("Pencil double-tap toggles the eraser, which is what it does by default")
    func doubleTap() {
        let state = ToolState()
        #expect(state.preferences.pencilDoubleTap == .toggleEraser)
        #expect(state.tool == .pen)

        state.handlePencilTap()
        #expect(state.tool == .eraser)
        state.handlePencilTap()
        #expect(state.tool == .pen)
    }

    @Test("Mapped to the previous tool, double-tap swaps back and forth")
    func doubleTapPrevious() {
        let state = ToolState()
        state.edit { $0.pencilDoubleTap = .previousTool }
        state.select(.eraser)
        state.select(.pen)
        state.handlePencilTap()
        #expect(state.tool == .eraser)
    }

    @Test("Cycle tools walks pen → eraser → tape → hand")
    func cycleTools() {
        let state = ToolState()
        state.edit { $0.pencilSqueeze = .cycleTools }
        let expected: [ToolState.Tool] = [.eraser, .tape, .hand, .pen]
        for tool in expected {
            state.handlePencilSqueeze()
            #expect(state.tool == tool)
        }
    }
}
