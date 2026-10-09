import CoreGraphics
import Testing
@testable import NotesEditor

@MainActor
@Suite("Editor keyboard shortcuts")
struct EditorShortcutTests {

    @Test("Each tool has its own key, and the everyday ones are all there")
    func toolKeys() {
        let keys = EditorScreen.toolShortcuts.map(\.key)
        #expect(Set(keys).count == keys.count)
        let tools = Set(EditorScreen.toolShortcuts.map(\.tool))
        #expect(tools.isSuperset(of: [.pen, .eraser, .lasso, .text, .hand]))
    }

    @Test("Next and previous page stop at the ends instead of wrapping")
    func stepping() {
        #expect(EditorScreen.steppedPage(from: 0, by: 1, count: 3) == 1)
        #expect(EditorScreen.steppedPage(from: 2, by: 1, count: 3) == nil, "already on the last page")
        #expect(EditorScreen.steppedPage(from: 0, by: -1, count: 3) == nil, "already on the first page")
        #expect(EditorScreen.steppedPage(from: nil, by: 1, count: 3) == 1, "no focus reads as page one")
        #expect(EditorScreen.steppedPage(from: nil, by: -1, count: 3) == 0)
        #expect(EditorScreen.steppedPage(from: 1, by: 1, count: 0) == nil)
    }

    @Test("Zoom in and out step a fixed ladder, so pressing back lands where you were")
    func zoomLadder() {
        #expect(EditorScreen.zoomStep(1, by: 1) == 1.25)
        #expect(EditorScreen.zoomStep(1.25, by: -1) == 1)
        #expect(EditorScreen.zoomStep(4, by: 1) == 4, "held at the top")
        #expect(EditorScreen.zoomStep(0.5, by: -1) == 0.5, "held at the bottom")
        #expect(EditorScreen.zoomStep(1.37, by: 1) == 1.5, "a pinched zoom steps to the next rung")
        #expect(EditorScreen.zoomStep(1.37, by: -1) == 1.25)
        for rung in EditorScreen.zoomLadder {
            #expect(EditorScreen.zoomRange.contains(rung), "every rung is a zoom the page allows")
        }
        var level: CGFloat = 1
        for _ in 0..<3 { level = EditorScreen.zoomStep(level, by: 1) }
        for _ in 0..<3 { level = EditorScreen.zoomStep(level, by: -1) }
        #expect(level == 1)
    }
}
