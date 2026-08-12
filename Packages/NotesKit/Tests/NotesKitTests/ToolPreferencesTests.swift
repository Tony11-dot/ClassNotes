import Foundation
import Testing
@testable import NotesEditor
@testable import NotesModels
@testable import NotesServices

@Suite("Settings that outlive the editor and reach the other device")
struct ToolPreferencesTests {
    @Test("A blob written by a newer build loads the fields this one understands")
    func decodesPartially() throws {
        // Settings are a convenience. A field this build has never heard of must
        // cost the user that field, never their whole setup.
        let json = """
        {"penPresetID":"fountain","eraserWidth":42,"somethingFromTheFuture":{"a":1}}
        """
        let decoded = try JSONDecoder().decode(ToolPreferences.self, from: Data(json.utf8))
        #expect(decoded.penPresetID == "fountain")
        #expect(decoded.eraserWidth == 42)
        // Everything absent falls back to the factory value rather than throwing.
        #expect(decoded.snapShapes == ToolPreferences().snapShapes)
        #expect(decoded.pencilSqueeze == ToolPreferences().pencilSqueeze)
    }

    @Test("Nonsense decodes to the factory setup instead of throwing")
    func survivesGarbage() {
        #expect(SettingsStore.decode(Data("not json".utf8)) == ToolPreferences())
        #expect(SettingsStore.decode(nil) == ToolPreferences())
    }

    @Test("A round trip keeps every field")
    func roundTrips() throws {
        var original = ToolPreferences()
        original.penPresetID = "marker"
        original.tuning["marker"] = PenSettings(thickness: 7, concentration: 0.6)
        original.eraserMode = .stroke
        original.scribbleToErase = true
        original.pencilDoubleTap = .undo
        original.pencilSqueeze = .askNova
        original.textSize = 33

        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ToolPreferences.self, from: data)
        #expect(back == original)
    }
}

@Suite("Which device's settings win")
struct DeviceSettingsMergeTests {
    private func settings(revision: Int, at seconds: TimeInterval) -> DeviceSettings {
        DeviceSettings(revision: revision, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test("The higher revision wins, whatever the clocks say")
    func revisionBeatsClock() {
        // The phone's clock is an hour AHEAD but it has made fewer changes.
        let iPad = settings(revision: 9, at: 1_000)
        let iPhone = settings(revision: 3, at: 4_600)
        #expect(DeviceSettings.newer(iPad, iPhone) == iPad)
        #expect(DeviceSettings.newer(iPhone, iPad) == iPad)
    }

    @Test("A tied revision falls back to the timestamp")
    func timestampBreaksTies() {
        let older = settings(revision: 4, at: 1_000)
        let newer = settings(revision: 4, at: 2_000)
        #expect(DeviceSettings.newer(older, newer) == newer)
    }

    @Test("Two identical copies resolve to the first, so the answer is stable")
    func stableOnTies() {
        let copy = settings(revision: 4, at: 1_000)
        #expect(DeviceSettings.newer(copy, copy) == copy)
    }
}

@MainActor
@Suite("Pencil gestures do what the user chose")
struct PencilActionTests {
    @Test("Double-tap and squeeze read their own settings")
    func mapsBothGestures() {
        let state = ToolState()
        state.edit {
            $0.pencilDoubleTap = .cycleTools
            $0.pencilSqueeze = .undo
        }
        state.select(.pen)

        #expect(state.handlePencilTap() == .handled)
        #expect(state.tool == .eraser)
        #expect(state.handlePencilSqueeze() == .undo)
    }

    @Test("What the state can't do itself comes back to the editor")
    func escalatesWhatItCannotDo() {
        let state = ToolState()
        #expect(state.perform(.showColors) == .showColors)
        #expect(state.perform(.toggleRuler) == .toggleRuler)
        #expect(state.perform(.askNova) == .askNova)
        // The tool must not have changed on the way out.
        #expect(state.tool == .pen)
    }

    @Test("Do nothing does nothing")
    func honoursNone() {
        let state = ToolState()
        state.select(.tape)
        #expect(state.perform(.none) == .handled)
        #expect(state.tool == .tape)
    }

    @Test("Cycling pens walks the tray and picks the pen up first")
    func cyclesPens() {
        let state = ToolState()
        state.select(.tape)
        state.perform(.cyclePens)
        // Holding something that isn't a pen, the first cycle picks one up
        // rather than silently doing nothing.
        #expect(state.tool == .pen)

        let first = state.penPresetID
        state.perform(.cyclePens)
        #expect(state.penPresetID != first)
    }

    @Test("Cycling pens wraps around the tray")
    func cyclingWraps() {
        let state = ToolState()
        state.select(.pen)
        let start = state.penPresetID
        for _ in PenLibrary.all { state.perform(.cyclePens) }
        #expect(state.penPresetID == start)
    }

    @Test("Select toggles the lasso and hands the previous tool back")
    func togglesLasso() {
        let state = ToolState()
        state.select(.pen)
        state.perform(.selectTool)
        #expect(state.tool == .lasso)
        state.perform(.selectTool)
        #expect(state.tool == .pen)
    }
}

@MainActor
@Suite("Tools without a store still work")
struct DetachedToolStateTests {
    @Test("Tuning applies with no settings store attached")
    func editsDetached() {
        // Previews and tests drive a bare ToolState; it must behave the same.
        let state = ToolState()
        state.eraserWidth = 44
        state.snapShapes = false
        #expect(state.eraserWidth == 44)
        #expect(state.snapShapes == false)
    }

    @Test("Per-instrument tuning stays with the instrument it was made for")
    func tuningIsPerPen() {
        let state = ToolState()
        let all = PenLibrary.all
        guard all.count >= 2 else { return }

        var tuned = state.settings(for: all[0])
        tuned.thickness = all[0].widthRange.upperBound
        state.setSettings(tuned, for: all[0])

        #expect(state.settings(for: all[0]).thickness == all[0].widthRange.upperBound)
        #expect(state.settings(for: all[1]) == all[1].defaults.normalized(in: all[1].widthRange))
    }
}
