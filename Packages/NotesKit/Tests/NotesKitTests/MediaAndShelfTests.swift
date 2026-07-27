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

@MainActor
@Suite("Changes made in the ClassMate tab", .serialized)
struct RemoteChangeTests {
    private func makeRepository() -> (NotebookRepository, ModelContext, ModelContainer) {
        // The container must be RETAINED (a ModelContext doesn't keep it alive), so
        // it's handed back to the test rather than dropped here.
        let container = ModelContainerFactory.make(inMemory: true)
        let repo = NotebookRepository(
            context: container.mainContext,
            store: DocumentStore(rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)),
            entitlements: EntitlementService(listenForUpdates: false)
        )
        return (repo, container.mainContext, container)
    }

    @Test("A rename in ClassMate is applied to the local notebook")
    func appliesRename() async throws {
        let (repo, context, container) = makeRepository()
        _ = container
        let notebook = Notebook(title: "Untitled Notebook 1", coverColorHex: "#111111")
        context.insert(notebook)
        try context.save()

        let applied = await repo.applyRemoteChanges(LibraryChanges(
            deletedIds: [],
            edited: [.init(
                id: notebook.id.uuidString, title: "  Physics  ",
                shelfId: nil, coverColorHex: "#2266DD"
            )]
        ))

        #expect(applied == [notebook.id.uuidString])
        #expect(notebook.title == "Physics")
        #expect(notebook.coverColorHex == "#2266DD")
    }

    @Test("A delete in ClassMate removes the local notebook")
    func appliesDelete() async throws {
        let (repo, context, container) = makeRepository()
        _ = container
        let doomed = Notebook(title: "Scratch", coverColorHex: "#111111")
        let keeper = Notebook(title: "Keep me", coverColorHex: "#111111")
        context.insert(doomed)
        context.insert(keeper)
        try context.save()

        let applied = await repo.applyRemoteChanges(
            LibraryChanges(deletedIds: [doomed.id.uuidString], edited: [])
        )

        #expect(applied == [doomed.id.uuidString])
        let remaining = try context.fetch(FetchDescriptor<Notebook>())
        #expect(remaining.map(\.title) == ["Keep me"])
    }

    @Test("Nothing is deleted without an explicit id — an empty pull is a no-op")
    func emptyChangesNeverDelete() async throws {
        // The pull must NEVER read "absent from the server" as "delete it here":
        // a fresh account, or a request that came back empty, would otherwise wipe
        // the whole library.
        let (repo, context, container) = makeRepository()
        _ = container
        for title in ["A", "B", "C"] {
            context.insert(Notebook(title: title, coverColorHex: "#111111"))
        }
        try context.save()

        let applied = await repo.applyRemoteChanges(LibraryChanges(deletedIds: [], edited: []))

        #expect(applied.isEmpty)
        #expect((try context.fetch(FetchDescriptor<Notebook>())).count == 3)
    }

    @Test("An id this device doesn't have is acknowledged, not retried forever")
    func unknownIDsAreAcknowledged() async throws {
        let (repo, _, container) = makeRepository()
        _ = container
        let stranger = UUID().uuidString
        let applied = await repo.applyRemoteChanges(
            LibraryChanges(deletedIds: [stranger], edited: [])
        )
        #expect(applied == [stranger])
    }
}
