import ClassMateTheme
import Foundation
import NotesModels
import Observation
import SwiftData

/// Mutations for the notebook library. Keeps the SwiftData row and the on-disk
/// document package in step; views read via `@Query` and mutate through here.
@MainActor
@Observable
public final class NotebookRepository {
    private let context: ModelContext
    private let store: DocumentStore
    private let entitlements: EntitlementService
    /// Optional so tests / previews can omit it; when present, every mutation
    /// mirrors up to the ClassMate backend for the ClassNotes tab.
    private let sync: SyncService?

    public init(
        context: ModelContext,
        store: DocumentStore,
        entitlements: EntitlementService,
        sync: SyncService? = nil
    ) {
        self.context = context
        self.store = store
        self.entitlements = entitlements
        self.sync = sync
    }

    // MARK: - Sync snapshots (built on @MainActor from the SwiftData rows)

    private func snapshot(_ n: Notebook) -> NotebookSnapshot {
        NotebookSnapshot(
            id: n.id, title: n.title, coverColorHex: n.coverColorHex,
            template: n.defaultTemplateRaw, shelfID: n.shelfID,
            createdAt: n.createdAt, updatedAt: n.updatedAt
        )
    }

    private func snapshot(_ s: Shelf) -> ShelfSnapshot {
        ShelfSnapshot(
            id: s.id, name: s.name, colorHex: s.colorHex,
            symbolName: s.symbolName, sortIndex: s.sortIndex, createdAt: s.createdAt
        )
    }

    /// A snapshot of the ENTIRE local library, for the launch full-sync.
    public func fullSnapshot() -> (notebooks: [NotebookSnapshot], shelves: [ShelfSnapshot]) {
        let notebooks = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        return (notebooks.map(snapshot), shelves.map(snapshot))
    }

    public func canCreateNotebook(currentCount: Int) -> Bool {
        entitlements.canCreateNotebook(currentCount: currentCount)
    }

    @discardableResult
    public func createNotebook(
        title: String,
        coverColor: ThemeColor,
        template: PageTemplate,
        margin: PageMargin = .default,
        paperColorHex: String? = nil,
        shelfID: UUID? = nil
    ) async throws -> Notebook {
        let notebook = Notebook(
            title: title.isEmpty ? "Untitled" : title,
            coverColorHex: coverColor.hexString,
            defaultTemplate: template
        )
        // File it straight into the active shelf, if any.
        notebook.shelfID = shelfID
        try await store.createDocument(
            id: notebook.id, firstPageTemplate: template,
            margin: margin, paperColorHex: paperColorHex
        )
        context.insert(notebook)
        try context.save()
        sync?.pushNotebook(snapshot(notebook))
        return notebook
    }

    public func rename(_ notebook: Notebook, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notebook.title = trimmed
        notebook.updatedAt = .now
        try context.save()
        sync?.pushNotebook(snapshot(notebook))
    }

    public func delete(_ notebook: Notebook) async throws {
        let id = notebook.id // capture before the row is deleted
        try await store.deleteDocument(id: notebook.id)
        context.delete(notebook)
        try context.save()
        sync?.deleteNotebook(id: id)
    }

    public func touch(_ notebook: Notebook) {
        notebook.updatedAt = .now
        try? context.save()
        sync?.pushNotebook(snapshot(notebook))
    }

    // MARK: - Shelves (bags / collections)

    @discardableResult
    public func createShelf(name: String, colorHex: String, symbolName: String) throws -> Shelf {
        let count = (try? context.fetchCount(FetchDescriptor<Shelf>())) ?? 0
        let shelf = Shelf(
            name: name.isEmpty ? "Shelf" : name,
            colorHex: colorHex,
            symbolName: symbolName,
            sortIndex: count
        )
        context.insert(shelf)
        try context.save()
        sync?.pushShelf(snapshot(shelf))
        return shelf
    }

    public func deleteShelf(_ shelf: Shelf) throws {
        let shelfID = shelf.id
        // Fetch-all-then-filter (predicate machinery is overkill for a tiny set
        // and traps on hostless test runners).
        let all = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        let unfiled = all.filter { $0.shelfID == shelfID }
        for notebook in unfiled { notebook.shelfID = nil }
        context.delete(shelf)
        try context.save()
        // Delete the shelf, then re-push the notebooks it un-filed so their
        // `shelfId` clears on the backend too.
        sync?.deleteShelf(id: shelfID)
        for notebook in unfiled { sync?.pushNotebook(snapshot(notebook)) }
    }

    public func assign(_ notebook: Notebook, toShelf shelfID: UUID?) {
        notebook.shelfID = shelfID
        notebook.updatedAt = .now
        try? context.save()
        sync?.pushNotebook(snapshot(notebook))
    }
}
