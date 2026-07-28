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
        try await create(
            title: title,
            coverColor: coverColor,
            style: PageStyle(
                template: template, margin: margin, paperColorHex: paperColorHex
            ),
            shelfID: shelfID
        )
    }

    /// The one path every creation flow goes through: quick note, the full New
    /// Notebook sheet, a whiteboard, and the image / file / scan imports. `kind`
    /// decides how the editor later presents it; `style` is the paper every page
    /// is cut to.
    @discardableResult
    public func create(
        title: String,
        coverColor: ThemeColor,
        style: PageStyle,
        kind: NotebookKind = .notebook,
        coverDesign: CoverDesign = .default,
        showsCover: Bool = true,
        pageCount: Int = 1,
        shelfID: UUID? = nil
    ) async throws -> Notebook {
        let notebook = Notebook(
            title: title.isEmpty ? Self.defaultTitle(for: kind) : title,
            coverColorHex: coverColor.hexString,
            defaultTemplate: style.template,
            shelfID: shelfID,
            kind: kind,
            coverDesign: coverDesign,
            showsCover: showsCover,
            pageSize: style.pageSize,
            orientation: style.orientation,
            paperColorHex: style.paperColorHex,
            lineColorHex: style.lineColorHex,
            lineSpacingSteps: style.lineSpacingSteps
        )
        // A paged notebook with the cover switch on gets its cover as page one,
        // so it can be drawn on like every other page.
        try await store.createDocument(
            id: notebook.id, style: style, pageCount: pageCount,
            includesCover: notebook.usesCoverPage
        )
        context.insert(notebook)
        try context.save()
        sync?.pushNotebook(snapshot(notebook))
        return notebook
    }

    /// A quick note: cover on, plain white A4 paper, two pages, ready instantly.
    @discardableResult
    public func createQuickNote(
        coverColor: ThemeColor, shelfID: UUID? = nil
    ) async throws -> Notebook {
        try await create(
            title: "",
            coverColor: coverColor,
            style: .quickNote,
            kind: .notebook,
            coverDesign: .default,
            pageCount: 2,
            shelfID: shelfID
        )
    }

    /// Imports pages (a PDF, photos, or a scan) into a brand-new document.
    /// Returns the notebook, or nil when nothing could be read.
    @discardableResult
    public func createFromImport(
        title: String,
        coverColor: ThemeColor,
        kind: NotebookKind,
        coverDesign: CoverDesign = .default,
        pdf: Data? = nil,
        images: [Data] = [],
        shelfID: UUID? = nil
    ) async throws -> Notebook? {
        let style = PageStyle.imported(size: .a4, orientation: .portrait)
        let notebook = try await create(
            title: title,
            coverColor: coverColor,
            style: style,
            kind: kind,
            coverDesign: coverDesign,
            shelfID: shelfID
        )
        // Every document starts with one page; the import goes in front of it and
        // that placeholder is then removed, so the notebook is purely the import.
        // (Never a cover page — imports don't have one, but be explicit.)
        let placeholder = try? await store.manifest(for: notebook.id)
            .pages.first(where: { !$0.isCover })?.id
        let imported: Bool
        if let pdf {
            imported = (try? await store.importPDF(
                data: pdf, notebook: notebook.id, at: 0, style: style
            ))?.firstPageID != nil
        } else {
            imported = (try? await store.importImages(
                images, notebook: notebook.id, at: 0, style: style
            ))?.firstPageID != nil
        }
        guard imported else {
            // Nothing readable — don't leave an empty stub in the library.
            try? await delete(notebook)
            return nil
        }
        if let placeholder = placeholder ?? nil {
            _ = try? await store.deletePage(notebook: notebook.id, page: placeholder)
        }
        sync?.pushNotebook(snapshot(notebook))
        return notebook
    }

    /// Drops a file onto a notebook's first page as an openable chip — used when a
    /// non-page file (a spreadsheet, an archive) is imported from the library.
    public func attachFile(
        _ data: Data, displayName: String, fileExtension: String, to notebookID: UUID
    ) async {
        // The first real page, never the cover — a dropped file belongs inside the
        // notebook, not stuck to the front of it.
        guard let manifest = try? await store.manifest(for: notebookID),
              let page = manifest.pages.first(where: { !$0.isCover }) ?? manifest.pages.first,
              let filename = try? await store.saveMedia(
                  data, notebook: notebookID, fileExtension: fileExtension
              ) else { return }
        let size = page.logicalSize
        let element = PageElement(
            kind: .file,
            x: max(0, (size.width - 280) / 2), y: max(0, (size.height - 72) / 2),
            width: 280, height: 72,
            payloadFilename: filename, displayName: displayName
        )
        _ = try? await store.setElements(
            page.elements + [element], notebook: notebookID, page: page.id
        )
    }

    private static func defaultTitle(for kind: NotebookKind) -> String {
        switch kind {
        case .notebook: "Untitled"
        case .whiteboard: "Whiteboard"
        case .image: "Image"
        case .document: "Document"
        case .scan: "Scan"
        }
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

    // MARK: - Applying changes made in ClassMate

    /// Applies the edits the user made in the ClassMate ClassNotes tab and returns
    /// the ids that were actually applied (the caller acknowledges those, so
    /// anything missed is retried next launch).
    ///
    /// Deletions are by EXPLICIT id — a notebook the server has never heard of is
    /// left completely alone. Nothing here pushes back: these values came FROM the
    /// server, and echoing them would just race the acknowledgement.
    @discardableResult
    public func applyRemoteChanges(_ changes: LibraryChanges) async -> [String] {
        let all = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        var byID: [UUID: Notebook] = [:]
        for notebook in all { byID[notebook.id] = notebook }
        var applied: [String] = []

        for raw in changes.deletedIds {
            guard let id = UUID(uuidString: raw) else { continue }
            guard let notebook = byID[id] else {
                // Already gone locally (deleted here too, or never on this device):
                // the tombstone has done its job, so let the server drop it.
                applied.append(raw)
                continue
            }
            do {
                try await store.deleteDocument(id: id)
                context.delete(notebook)
                applied.append(raw)
            } catch {
                // Leave it unacknowledged; the next launch tries again.
                continue
            }
        }

        for edit in changes.edited {
            guard let id = UUID(uuidString: edit.id) else { continue }
            guard let notebook = byID[id] else {
                applied.append(edit.id)
                continue
            }
            let title = edit.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { notebook.title = title }
            if !edit.coverColorHex.isEmpty { notebook.coverColorHex = edit.coverColorHex }
            // A missing shelfId means unfiled — that's a real change, not "unknown".
            notebook.shelfID = edit.shelfId.flatMap(UUID.init(uuidString:))
            applied.append(edit.id)
        }

        if !applied.isEmpty { try? context.save() }
        return applied
    }

    public func assign(_ notebook: Notebook, toShelf shelfID: UUID?) {
        notebook.shelfID = shelfID
        notebook.updatedAt = .now
        try? context.save()
        sync?.pushNotebook(snapshot(notebook))
    }
}
