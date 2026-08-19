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

@MainActor
@Suite("Notebooks discovered on the account but not on this device", .serialized)
struct RemoteLibraryDiscoveryTests {
    private func makeRepository() -> (NotebookRepository, ModelContext, ModelContainer) {
        let container = ModelContainerFactory.make(inMemory: true)
        let repo = NotebookRepository(
            context: container.mainContext,
            store: DocumentStore(rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)),
            entitlements: EntitlementService(listenForUpdates: false)
        )
        return (repo, container.mainContext, container)
    }

    private func entry(
        id: String = UUID().uuidString, title: String = "From the iPad",
        shelfId: String? = nil, updatedAt: Date = .now
    ) -> RemoteLibrary.Entry {
        RemoteLibrary.Entry(
            id: id, title: title, coverColorHex: "#2266DD", coverImage: nil,
            template: "ruled", shelfId: shelfId, pageCount: 3,
            createdAt: .now, updatedAt: updatedAt
        )
    }

    @Test("A notebook only the server knows about is created locally, marked remote-only")
    func createsMissingNotebook() async throws {
        let (repo, context, container) = makeRepository()
        _ = container
        let remoteID = UUID()
        await repo.applyRemoteLibrary(RemoteLibrary(notebooks: [entry(id: remoteID.uuidString, title: "Physics")]))

        let all = try context.fetch(FetchDescriptor<Notebook>())
        #expect(all.count == 1)
        #expect(all.first?.id == remoteID)
        #expect(all.first?.title == "Physics")
        #expect(all.first?.isRemoteOnly == true)
    }

    @Test("A local package already on disk is adopted, not shadowed as remote-only")
    func selfHealsLocalPackageMistakenForRemoteOnly() async throws {
        let (repo, context, container) = makeRepository()
        _ = container
        let id = UUID()
        // A real .cmnote package exists on disk for this id, but (simulating
        // the race the self-heal guards against) no local `Notebook` row
        // exists — without the disk check, this would be recreated with
        // `isRemoteOnly = true` and get stuck permanently read-only.
        _ = try await repo.store.createDocument(id: id, firstPageTemplate: .ruled)

        await repo.applyRemoteLibrary(RemoteLibrary(notebooks: [entry(id: id.uuidString, title: "Physics")]))

        let all = try context.fetch(FetchDescriptor<Notebook>())
        #expect(all.count == 1)
        #expect(all.first?.id == id)
        #expect(all.first?.isRemoteOnly == false)
    }

    @Test("A notebook already known locally keeps its own edit when the server's copy is no newer")
    func leavesKnownNotebookAlone() async throws {
        let (repo, context, container) = makeRepository()
        _ = container
        let notebook = Notebook(title: "My own edit", coverColorHex: "#111111")
        notebook.updatedAt = Date(timeIntervalSinceNow: 60)
        context.insert(notebook)
        try context.save()

        await repo.applyRemoteLibrary(RemoteLibrary(
            notebooks: [entry(
                id: notebook.id.uuidString, title: "Stale server title",
                updatedAt: Date(timeIntervalSinceNow: -60)
            )]
        ))

        let all = try context.fetch(FetchDescriptor<Notebook>())
        #expect(all.count == 1)
        #expect(all.first?.title == "My own edit")
        #expect(all.first?.isRemoteOnly == false)
    }

    @Test("A rename/reshelve made on another device is adopted once it's newer than this device's copy")
    func adoptsNewerRemoteEdit() async throws {
        let (repo, context, container) = makeRepository()
        _ = container
        let notebook = Notebook(title: "Old title", coverColorHex: "#111111")
        notebook.updatedAt = Date(timeIntervalSinceNow: -60)
        context.insert(notebook)
        try context.save()

        await repo.applyRemoteLibrary(RemoteLibrary(
            notebooks: [entry(
                id: notebook.id.uuidString, title: "Renamed on the iPad",
                updatedAt: Date(timeIntervalSinceNow: 60)
            )]
        ))

        let all = try context.fetch(FetchDescriptor<Notebook>())
        #expect(all.count == 1)
        #expect(all.first?.title == "Renamed on the iPad")
        // Still a real local notebook with its own ink package — only its
        // metadata was refreshed, not its ownership.
        #expect(all.first?.isRemoteOnly == false)
    }

    @Test("An empty or unreachable pull creates nothing and deletes nothing")
    func emptyPullIsANoOp() async throws {
        let (repo, context, container) = makeRepository()
        _ = container
        context.insert(Notebook(title: "Untouched", coverColorHex: "#111111"))
        try context.save()

        await repo.applyRemoteLibrary(RemoteLibrary(notebooks: []))

        let all = try context.fetch(FetchDescriptor<Notebook>())
        #expect(all.count == 1)
        #expect(all.first?.title == "Untouched")
    }
}
