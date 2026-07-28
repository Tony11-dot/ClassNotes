import Foundation
import NotesModels

/// A `Sendable` value snapshot of a `Notebook` (a SwiftData `@Model` is neither
/// `Sendable` nor safe off the main actor), taken on `@MainActor` and handed to
/// the sync layer.
public struct NotebookSnapshot: Sendable {
    public let id: UUID
    public let title: String
    public let coverColorHex: String
    public let template: String        // PageTemplate.rawValue
    public let shelfID: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID, title: String, coverColorHex: String, template: String,
        shelfID: UUID?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.coverColorHex = coverColorHex
        self.template = template
        self.shelfID = shelfID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A `Sendable` value snapshot of a `Shelf`.
public struct ShelfSnapshot: Sendable {
    public let id: UUID
    public let name: String
    public let colorHex: String
    public let symbolName: String
    public let sortIndex: Int
    public let createdAt: Date

    public init(
        id: UUID, name: String, colorHex: String, symbolName: String,
        sortIndex: Int, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// Best-effort mirror of the local notebook library up to the ClassMate backend,
/// so the ClassMate "ClassNotes" tab shows the user's real books. Fire-and-forget
/// per mutation — a failed push is reconciled by the next edit or the launch
/// full-sync; there's no offline queue yet. `@MainActor` because it reads the
/// auth token (owned by the `@MainActor` `AuthService`); the network + disk work
/// runs off the main actor inside the awaited calls.
@MainActor
public final class SyncService {
    private let client: ClassMateAPIClient
    private let auth: AuthService
    private let store: DocumentStore

    public init(client: ClassMateAPIClient, auth: AuthService, store: DocumentStore) {
        self.client = client
        self.auth = auth
        self.store = store
    }

    // MARK: - Per-mutation hooks (call on @MainActor from NotebookRepository)

    public func pushNotebook(_ snapshot: NotebookSnapshot) {
        guard let token = auth.token else { return }
        let client = client
        let store = store
        Task {
            // Page count lives in the on-disk manifest, not the SwiftData row.
            let pages = (try? await store.manifest(for: snapshot.id).pages.count) ?? 1
            // The cover the user actually drew, so ClassMate's tile matches the
            // iPad's. Absent until the editor has rendered one.
            let cover = await store.coverImageData(for: snapshot.id)
                .map { "data:image/png;base64,\($0.base64EncodedString())" }
            let body = NotebookSyncBody(
                title: snapshot.title,
                coverColorHex: snapshot.coverColorHex,
                template: snapshot.template,
                shelfId: snapshot.shelfID?.uuidString,
                pageCount: max(pages, 1),
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                coverImage: cover
            )
            try? await client.putNotebook(id: snapshot.id.uuidString, body: body, token: token)
        }
    }

    public func deleteNotebook(id: UUID) {
        guard let token = auth.token else { return }
        let client = client
        Task { try? await client.deleteNotebook(id: id.uuidString, token: token) }
    }

    public func pushShelf(_ snapshot: ShelfSnapshot) {
        guard let token = auth.token else { return }
        let client = client
        Task {
            let body = ShelfSyncBody(
                name: snapshot.name,
                colorHex: snapshot.colorHex,
                symbolName: snapshot.symbolName,
                sortIndex: snapshot.sortIndex,
                createdAt: snapshot.createdAt
            )
            try? await client.putShelf(id: snapshot.id.uuidString, body: body, token: token)
        }
    }

    public func deleteShelf(id: UUID) {
        guard let token = auth.token else { return }
        let client = client
        Task { try? await client.deleteShelf(id: id.uuidString, token: token) }
    }

    /// Upload rendered page images (PNG data URLs) so the ClassMate ClassNotes
    /// tab shows real content. The editor renders these on the main actor and
    /// hands them here; best-effort, fire-and-forget.
    public func pushPageImages(notebookID: UUID, images: [NotebookPageImage]) {
        guard let token = auth.token, !images.isEmpty else { return }
        let client = client
        Task {
            let body = NotebookPagesBody(pages: images, pageCount: images.count)
            try? await client.putNotebookPages(id: notebookID.uuidString, body: body, token: token)
        }
    }

    // MARK: - Full sync (launch)

    /// Push every local record so the backend catches up on first run and after
    /// any missed per-mutation pushes. Shelves first so notebook `shelfId`s land
    /// against existing shelves.
    public func pushAll(notebooks: [NotebookSnapshot], shelves: [ShelfSnapshot]) {
        for shelf in shelves { pushShelf(shelf) }
        for notebook in notebooks { pushNotebook(notebook) }
    }

    // MARK: - Pull (launch, before pushing)

    /// Applies what the user changed from the ClassMate ClassNotes tab — notebooks
    /// they deleted or renamed there — then acknowledges them.
    ///
    /// This MUST run before `pushAll`, because a push would otherwise send the
    /// stale local title straight back over a rename made in ClassMate. Deletions
    /// are applied by EXPLICIT id only: "absent from the server" is never taken as
    /// a reason to delete anything locally, so a fresh account or a failed request
    /// can't wipe the library.
    ///
    /// `apply` does the local work on the main actor and returns the ids it
    /// actually handled; only those are acknowledged, so anything that failed is
    /// retried on the next launch.
    public func pullRemoteChanges(
        apply: @MainActor (LibraryChanges) async -> [String]
    ) async {
        guard let token = auth.token else { return }
        guard let changes = try? await client.fetchLibraryChanges(token: token),
              !changes.isEmpty else { return }
        let applied = await apply(changes)
        try? await client.acknowledgeChanges(ids: applied, token: token)
    }
}
