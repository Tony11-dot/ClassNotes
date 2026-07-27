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

    @Test("Tray instruments cover every PencilKit ink family we offer")
    func trayCoversInkFamilies() {
        let inks = Set(PenLibrary.all.map(\.ink))
        #expect(inks.contains(.monoline))
        #expect(inks.contains(.pen))
        #expect(inks.contains(.pencil))
        #expect(inks.contains(.fountainPen))
        #expect(inks.contains(.marker))
        #expect(inks.contains(.watercolor))
        #expect(inks.contains(.crayon))
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
        let flow = PenLibrary.flow
        let brush = PenLibrary.preset(id: "brush")

        #expect(state.selectPen(flow) == true, "flow is selected by default")
        #expect(state.selectPen(brush) == false, "first tap only picks the brush up")
        #expect(state.selectPen(brush) == true, "second tap asks for its settings")
    }

    @Test("Each instrument keeps its own tuning")
    func perPenTuning() {
        let state = ToolState()
        let flow = PenLibrary.flow
        let brush = PenLibrary.preset(id: "brush")

        state.selectPen(flow)
        state.currentWidth = 4
        state.selectPen(brush)
        state.currentWidth = 14

        #expect(state.settings(for: flow).thickness == 4)
        #expect(state.settings(for: brush).thickness == 14)

        state.resetPen(brush)
        #expect(state.settings(for: brush).thickness == brush.defaults.thickness)
        #expect(state.settings(for: flow).thickness == 4, "resetting one pen leaves the others alone")
    }

    @Test("Tuning is clamped into each instrument's own range")
    func tuningClamped() {
        let state = ToolState()
        let flow = PenLibrary.flow
        state.setSettings(
            PenSettings(stability: 99, tip: 5, sensitivity: -3, thickness: 900, concentration: 0),
            for: flow
        )
        let settings = state.settings(for: flow)
        #expect(settings.stability == PenSettings.stabilityRange.upperBound)
        #expect(settings.tip == 1)
        #expect(settings.sensitivity == 0)
        #expect(settings.thickness == flow.widthRange.upperBound)
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

    @Test("Pencil double-tap toggles eraser and honors switch-previous")
    func doubleTap() {
        let state = ToolState()
        #expect(state.tool == .pen)

        state.handlePencilTap(preferred: .switchEraser)
        #expect(state.tool == .eraser)
        state.handlePencilTap(preferred: .switchEraser)
        #expect(state.tool == .pen)

        state.select(.eraser)
        state.select(.pen)
        state.handlePencilTap(preferred: .switchPrevious)
        #expect(state.tool == .eraser)
    }

    @Test("Pencil squeeze cycles pen → eraser → tape → hand")
    func squeeze() {
        let state = ToolState()
        let expected: [ToolState.Tool] = [.eraser, .tape, .hand, .pen]
        for tool in expected {
            state.handlePencilSqueeze()
            #expect(state.tool == tool)
        }
    }
}
