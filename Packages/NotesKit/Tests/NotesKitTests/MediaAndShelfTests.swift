import Foundation
import NotesModels
import SwiftData
import Testing
@testable import NotesServices

@Suite("Media + element persistence")
struct MediaStoreTests {
    private func makeStore() -> (DocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-media-\(UUID().uuidString)", isDirectory: true)
        return (DocumentStore(rootURL: root), root)
    }

    @Test("Media payload saves and reads back")
    func mediaRoundTrip() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .ruled)
        let filename = try await store.saveMedia(Data("img".utf8), notebook: id, fileExtension: "jpg")
        #expect(filename.hasSuffix(".jpg"))
        #expect(await store.mediaData(notebook: id, filename: filename) == Data("img".utf8))
    }

    @Test("Page elements persist through the manifest and survive reload")
    func elementsPersist() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let manifest = try await store.createDocument(id: id, firstPageTemplate: .ruled)
        let page = manifest.pages[0].id
        let element = PageElement(kind: .audio, x: 0, y: 0, width: 240, height: 52,
                                  payloadFilename: "a.m4a", durationSeconds: 3.2)
        _ = try await store.setElements([element], notebook: id, page: page)

        let reloaded = try await store.manifest(for: id)
        #expect(reloaded.pages[0].elements.count == 1)
        #expect(reloaded.pages[0].elements.first?.durationSeconds == 3.2)
    }
}

@MainActor
@Suite("Shelves", .serialized)
struct ShelfTests {
    @Test("Create, assign, and delete a shelf reassigns its notebooks")
    func shelfLifecycle() throws {
        let container = ModelContainerFactory.make(inMemory: true)
        let context = container.mainContext
        let entitlements = EntitlementService(listenForUpdates: false)
        let repo = NotebookRepository(
            context: context,
            store: DocumentStore(rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)),
            entitlements: entitlements
        )

        let shelf = try repo.createShelf(name: "Biology", colorHex: "#416835", symbolName: "flask")
        let notebook = Notebook(title: "Cells", coverColorHex: "#416835")
        context.insert(notebook)
        try context.save()

        repo.assign(notebook, toShelf: shelf.id)
        #expect(notebook.shelfID == shelf.id)

        try repo.deleteShelf(shelf)
        #expect(notebook.shelfID == nil)
        #expect((try context.fetch(FetchDescriptor<Shelf>())).isEmpty)
    }
}
