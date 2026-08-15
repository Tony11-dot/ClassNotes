import Foundation
import NotesModels
import SwiftData
import Testing
@testable import NotesServices

/// The grace period, as arithmetic. Nothing here needs a database or a month of
/// waiting — which is the point of keeping it pure.
@Suite("How long the trash keeps things")
struct TrashPolicyTests {
    private let deleted = Date(timeIntervalSince1970: 1_000_000)

    @Test("A notebook that was never deleted is never expired")
    func liveNotebooksNeverExpire() {
        // The dangerous reading of `deletedAt == nil` is "deleted at the epoch",
        // which would make the purge treat the whole live library as overdue.
        #expect(!TrashPolicy.isExpired(deletedAt: nil, now: .distantFuture))
        #expect(TrashPolicy.daysRemaining(deletedAt: nil) == 0)
    }

    @Test("It expires on the day it runs out, not before")
    func expiresAtTheBoundary() {
        let almost = deleted.addingTimeInterval(TrashPolicy.retention - 1)
        let exactly = deleted.addingTimeInterval(TrashPolicy.retention)
        #expect(!TrashPolicy.isExpired(deletedAt: deleted, now: almost))
        #expect(TrashPolicy.isExpired(deletedAt: deleted, now: exactly))
        #expect(TrashPolicy.isExpired(deletedAt: deleted, now: exactly.addingTimeInterval(86_400)))
    }

    @Test("The countdown reads the way people count days")
    func countdownReadsNaturally() {
        #expect(TrashPolicy.daysRemaining(deletedAt: deleted, now: deleted) == 30)
        let dayLeft = deleted.addingTimeInterval(TrashPolicy.retention - 3_600)
        #expect(TrashPolicy.expiryLabel(deletedAt: deleted, now: dayLeft) == "1 day left")
        let overdue = deleted.addingTimeInterval(TrashPolicy.retention + 1)
        #expect(TrashPolicy.expiryLabel(deletedAt: deleted, now: overdue) == "Deleting today")
    }
}

@MainActor
@Suite("Deleting a notebook doesn't destroy it", .serialized)
struct TrashRepositoryTests {
    private func makeRepository() -> (NotebookRepository, ModelContext, ModelContainer, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-trash-\(UUID().uuidString)", isDirectory: true)
        // The container must be RETAINED — a ModelContext doesn't keep it alive.
        let container = ModelContainerFactory.make(inMemory: true)
        let repo = NotebookRepository(
            context: container.mainContext,
            store: DocumentStore(rootURL: root),
            entitlements: EntitlementService(listenForUpdates: false)
        )
        return (repo, container.mainContext, container, root)
    }

    private func insert(_ title: String, into context: ModelContext) throws -> Notebook {
        let notebook = Notebook(title: title, coverColorHex: "#111111")
        context.insert(notebook)
        try context.save()
        return notebook
    }

    @Test("Deleting leaves the row and the ink exactly where they were")
    func trashKeepsEverything() async throws {
        let (repo, context, container, root) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = container
        let notebook = try insert("Physics", into: context)
        let store = DocumentStore(rootURL: root)
        _ = try await store.createDocument(id: notebook.id, firstPageTemplate: .ruled)

        try repo.moveToTrash(notebook)

        #expect(notebook.isTrashed)
        #expect(notebook.deletedAt != nil)
        // The row is still in the database and the package is still on disk —
        // that is the entire promise of a trash.
        #expect((try context.fetch(FetchDescriptor<Notebook>())).count == 1)
        #expect(await store.documentExists(id: notebook.id))
    }

    @Test("Deleting twice doesn't restart the clock")
    func trashIsIdempotent() throws {
        let (repo, context, container, root) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = container
        let notebook = try insert("Physics", into: context)

        try repo.moveToTrash(notebook)
        let first = notebook.deletedAt
        try repo.moveToTrash(notebook)

        // Re-stamping would silently extend the grace period every time the
        // notebook was touched, so nothing would ever actually be purged.
        #expect(notebook.deletedAt == first)
    }

    @Test("Restoring puts it back in the library")
    func restoreReturnsIt() throws {
        let (repo, context, container, root) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = container
        let notebook = try insert("Physics", into: context)

        try repo.moveToTrash(notebook)
        try repo.restore(notebook)

        #expect(!notebook.isTrashed)
        #expect(repo.trashedNotebooks().isEmpty)
    }

    @Test("Purging is the step that actually removes the ink")
    func purgeDestroys() async throws {
        let (repo, context, container, root) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = container
        let notebook = try insert("Scratch", into: context)
        let store = DocumentStore(rootURL: root)
        _ = try await store.createDocument(id: notebook.id, firstPageTemplate: .ruled)
        let id = notebook.id

        try repo.moveToTrash(notebook)
        try await repo.purge(notebook)

        #expect((try context.fetch(FetchDescriptor<Notebook>())).isEmpty)
        #expect(!(await store.documentExists(id: id)))
    }

    @Test("The launch purge takes only what has run out of time")
    func purgeExpiredSparesTheRest() async throws {
        let (repo, context, container, root) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = container
        let old = try insert("Old", into: context)
        let recent = try insert("Recent", into: context)
        let live = try insert("Live", into: context)

        try repo.moveToTrash([old, recent])
        // Backdate one past the grace period.
        old.deletedAt = Date.now.addingTimeInterval(-TrashPolicy.retention - 60)
        try context.save()

        let purged = await repo.purgeExpiredTrash()

        #expect(purged == 1)
        let remaining = (try context.fetch(FetchDescriptor<Notebook>())).map(\.title).sorted()
        #expect(remaining == ["Live", "Recent"])
        #expect(!live.isTrashed)
    }

    @Test("Trashed notebooks leave the library, the sync push and search")
    func trashedNotebooksAreInvisible() throws {
        let (repo, context, container, root) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = container
        let kept = try insert("Kept", into: context)
        let gone = try insert("Gone", into: context)

        try repo.moveToTrash(gone)

        // Pushing a trashed notebook would put it straight back into the
        // ClassNotes tab; offering it to search would list something that can't
        // be opened.
        #expect(repo.fullSnapshot().notebooks.map(\.title) == ["Kept"])
        #expect(repo.searchTargets().map(\.title) == ["Kept"])
        #expect(repo.trashedNotebooks().map(\.title) == ["Gone"])
        #expect(!kept.isTrashed)
    }

    @Test("Emptying the trash spares the library")
    func emptyTrashOnlyTakesTheTrash() async throws {
        let (repo, context, container, root) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = container
        let kept = try insert("Kept", into: context)
        let gone = try insert("Gone", into: context)
        try repo.moveToTrash(gone)

        try await repo.emptyTrash()

        #expect((try context.fetch(FetchDescriptor<Notebook>())).map(\.title) == ["Kept"])
        #expect(!kept.isTrashed)
    }

    @Test("Starring a notebook sticks")
    func favouritesToggle() throws {
        let (repo, context, container, root) = makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = container
        let notebook = try insert("Physics", into: context)

        #expect(!notebook.isFavorite)
        try repo.toggleFavorite(notebook)
        #expect(notebook.isFavorite)
        try repo.toggleFavorite(notebook)
        #expect(!notebook.isFavorite)
    }
}

@Suite("Bookmarked pages")
struct PageBookmarkTests {
    private func makeStore() -> (DocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-marks-\(UUID().uuidString)", isDirectory: true)
        return (DocumentStore(rootURL: root), root)
    }

    @Test("A page can be flagged, named, and unflagged")
    func bookmarkRoundTrip() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let manifest = try await store.createDocument(id: id, style: PageStyle(), pageCount: 2)
        let page = manifest.pages[1].id

        var updated = try await store.setBookmark(
            notebook: id, page: page, isBookmarked: true, name: "  Redox  "
        )
        #expect(updated.pages[1].isBookmarked)
        #expect(updated.pages[1].bookmarkName == "Redox")
        #expect(updated.bookmarkedPages.map(\.id) == [page])

        updated = try await store.setBookmark(notebook: id, page: page, isBookmarked: false)
        #expect(!updated.pages[1].isBookmarked)
        // Clearing the flag clears the name, or re-flagging would silently bring
        // back a title the user had already thrown away.
        #expect(updated.pages[1].bookmarkName == nil)
    }

    @Test("Flagging one page leaves the others alone")
    func bookmarksAreLocal() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let manifest = try await store.createDocument(id: id, style: PageStyle(), pageCount: 3)

        let updated = try await store.setBookmark(
            notebook: id, page: manifest.pages[1].id, isBookmarked: true
        )

        #expect(updated.pages.filter(\.isBookmarked).count == 1)
        #expect(updated.pages[1].isBookmarked)
    }

    @Test("A bookmark survives being written and read back")
    func bookmarkPersists() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let manifest = try await store.createDocument(id: id, style: PageStyle(), pageCount: 1)
        _ = try await store.setBookmark(
            notebook: id, page: manifest.pages[0].id, isBookmarked: true, name: "Formula sheet"
        )

        let reloaded = try await store.manifest(for: id)

        #expect(reloaded.bookmarkedPages.first?.bookmarkName == "Formula sheet")
    }

    @Test("A manifest written before bookmarks existed loads with none")
    func olderManifestsDecode() throws {
        // v7 shape: every key bookmarks added is absent.
        let json = """
        {"version":7,"pages":[{"id":"\(UUID().uuidString)","template":"ruled",
        "createdAt":"2025-01-01T00:00:00Z","elements":[],"isCover":false,
        "pageSize":"a4","orientation":"portrait","lineSpacingSteps":3,
        "margin":{"position":"none","offset":72}}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(NotebookManifest.self, from: Data(json.utf8))

        #expect(manifest.pages.count == 1)
        #expect(!manifest.pages[0].isBookmarked)
        #expect(manifest.pages[0].bookmarkName == nil)
    }
}
