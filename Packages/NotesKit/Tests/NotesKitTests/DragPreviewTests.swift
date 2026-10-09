import ClassMateTheme
@testable import NotesLibrary
import NotesModels
import NotesServices
import SwiftUI
import Testing

/// A drag preview is hosted on its own, outside the view tree, and inherits
/// nothing from the environment. Rendering one with no ancestor around it is
/// exactly the situation the system puts it in. A preview that reads an object
/// nobody handed it traps here the way the app did on the iPad: long-press a
/// cover in the library, move a little, and the app quit (1.5 (80)–(82)).
@MainActor
@Suite("Drag previews")
struct DragPreviewTests {
    @Test("A cover's drag preview renders with nothing around it")
    func coverDragPreviewIsSelfContained() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-drag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = AppServices(
            modelContainer: ModelContainerFactory.make(inMemory: true),
            documentsRootURL: root
        )
        let notebook = try await services.repository.create(
            title: "Physics", coverColor: ThemePreset.dark.spec.accent, style: .quickNote
        )

        let preview = NotebookCoverTile.dragPreview(
            notebook, services: services, theme: ThemePreset.dark.spec
        )
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        let image = try #require(renderer.uiImage)

        // 110 points wide, as the preview is framed.
        #expect(image.size.width == 110)
        #expect(image.size.height > 0)
    }
}
