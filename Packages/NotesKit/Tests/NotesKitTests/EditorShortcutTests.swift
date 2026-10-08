import Testing
@testable import NotesEditor

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
}
