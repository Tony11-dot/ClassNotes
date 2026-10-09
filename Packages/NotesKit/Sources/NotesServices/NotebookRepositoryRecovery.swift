import ClassMateTheme
import Foundation
import NotesModels
import SwiftData

/// What a launch reconciliation found and fixed.
public struct LibraryReconciliation: Sendable, Equatable {
    /// Packages on disk that had no row and were put back in the library.
    public var recovered: Int = 0
    /// Of those, how many had no description of their own and came back under
    /// a placeholder name.
    public var recoveredWithoutDescription: Int = 0

    public init(recovered: Int = 0, recoveredWithoutDescription: Int = 0) {
        self.recovered = recovered
        self.recoveredWithoutDescription = recoveredWithoutDescription
    }
}

/// Keeping the library and the documents on disk the same set of notebooks.
public extension NotebookRepository {

    /// Writes each notebook's description (`info.json`) into its package so the
    /// notebook can always be rebuilt from the package alone. Called after every
    /// change to a row; a package with nothing new is not rewritten.
    func mirrorInfo(_ notebooks: [Notebook]) async {
        for info in infoSnapshots(notebooks) {
            try? await store.writeInfo(info)
        }
    }

    /// Fire-and-forget `mirrorInfo` for the synchronous mutators.
    ///
    /// The descriptions are taken NOW and only the writing is deferred. The
    /// task used to read the rows themselves when it got round to running, and
    /// by then a row can be gone — purged straight after a trash, or its whole
    /// container released — and SwiftData traps on a read of either.
    internal func mirrorInfoSoon(_ notebooks: [Notebook]) {
        let infos = infoSnapshots(notebooks)
        guard !infos.isEmpty else { return }
        let store = store
        Task {
            for info in infos { try? await store.writeInfo(info) }
        }
    }

    /// Each live row's description, read synchronously while the rows are
    /// certainly still there.
    internal func infoSnapshots(_ notebooks: [Notebook]) -> [NotebookInfo] {
        let live = notebooks.filter { !$0.isDeleted && $0.modelContext != nil }
        guard !live.isEmpty else { return [] }
        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        var shelfByID: [UUID: Shelf] = [:]
        for shelf in shelves { shelfByID[shelf.id] = shelf }
        return live.map { notebook in
            notebook.info(shelf: notebook.shelfID.flatMap { shelfByID[$0] })
        }
    }

    /// Puts every notebook package on this device into the library. Run at
    /// launch, before anything reads, syncs or purges the library.
    ///
    /// The library lists ROWS, and a package with no row was invisible: the ink
    /// on disk and nothing on screen. A crash between writing a new notebook's
    /// package and saving its row did that, and so did a metadata store that
    /// couldn't be opened (see `ModelContainerFactory`), which used to leave the
    /// user looking at an empty library. Each package is brought back from its
    /// own `info.json` (title, cover, shelf, even whether it was in the trash);
    /// one written before descriptions existed comes back as "Recovered
    /// notebook" with its pages intact.
    ///
    /// Never deletes anything, and never touches a row that already exists
    /// beyond clearing a stale remote-only flag on one whose package is here,
    /// or setting aside a stand-in (`DocumentStore.isStandIn`) that isn't.
    @discardableResult
    func reconcileWithDisk() async -> LibraryReconciliation {
        let packageIDs = await store.packageIDs()
        let rows = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        var rowByID: [UUID: Notebook] = [:]
        for row in rows { rowByID[row.id] = row }
        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        var shelfByID: [UUID: Shelf] = [:]
        for shelf in shelves { shelfByID[shelf.id] = shelf }

        var result = LibraryReconciliation()
        var changed = false
        for id in packageIDs {
            if let row = rowByID[id] {
                if await settle(row) { changed = true }
                continue
            }
            let notebook: Notebook
            if let info = await store.info(for: id) {
                notebook = Notebook(info: info)
                if let shelfID = info.shelfID, shelfByID[shelfID] == nil {
                    if let name = info.shelfName {
                        let shelf = Shelf(
                            id: shelfID, name: name,
                            colorHex: info.shelfColorHex ?? ThemePreset.light.accent.hexString,
                            symbolName: info.shelfSymbol ?? "bag",
                            sortIndex: shelfByID.count
                        )
                        context.insert(shelf)
                        shelfByID[shelfID] = shelf
                    } else {
                        notebook.shelfID = nil
                    }
                }
            } else {
                notebook = await placeholderRow(for: id)
                result.recoveredWithoutDescription += 1
            }
            context.insert(notebook)
            rowByID[id] = notebook
            result.recovered += 1
            changed = true
        }
        if changed { try? context.save() }
        // Backfill: every notebook with a package gets (or refreshes) its
        // description, so the next recovery has names to put back.
        let withPackages = Set(packageIDs)
        await mirrorInfo(rowByID.values.filter { withPackages.contains($0.id) })
        if result.recovered > 0 {
            Perf.event("Library recovered notebooks")
        }
        return result
    }

    /// Squares a row with the package found for it; true when the row changed.
    ///
    /// A package here means the notebook is this device's — unless it is a
    /// stand-in an older build wrote for a notebook that lives on another
    /// device. Taken for that notebook, a stand-in opened as a blank page in
    /// the editor, and leaving pushed the blank page over the real ones on the
    /// server. It holds nothing, so it is set aside and the notebook reads from
    /// the server again — also when 1.5 (84) had already flipped the row to
    /// local. While the editor has it open, nothing changes.
    private func settle(_ row: Notebook) async -> Bool {
        if await store.isStandIn(row.id, notebookCreatedAt: row.createdAt) {
            guard (try? await store.setAside(row.id)) != nil, !row.isRemoteOnly else { return false }
            row.isRemoteOnly = true
            return true
        }
        guard row.isRemoteOnly else { return false }
        row.isRemoteOnly = false
        return true
    }

    /// A row for a package with no description: a placeholder name, the date
    /// the package was made, and whatever the manifest says about its pages.
    private func placeholderRow(for id: UUID) async -> Notebook {
        let manifest = try? await store.manifest(for: id)
        let firstPage = manifest?.pages.first { !$0.isCover } ?? manifest?.pages.first
        return Notebook(
            id: id,
            title: "Recovered notebook",
            coverColorHex: ThemePreset.light.accent.hexString,
            defaultTemplate: firstPage?.template ?? .ruled,
            createdAt: await store.packageCreatedAt(id: id) ?? .now,
            kind: .notebook,
            showsCover: manifest?.hasCoverPage ?? false,
            pageSize: firstPage?.pageSize ?? .classic,
            orientation: firstPage?.orientation ?? .portrait
        )
    }
}
