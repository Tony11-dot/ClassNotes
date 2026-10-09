import ClassMateTheme
import Foundation
import NotesModels
import SwiftData

/// What sync asks of the library's rows: the account mirror's launch push,
/// and iCloud (D-003).
extension NotebookRepository {

    /// A snapshot of the ENTIRE local library, for the launch full-sync.
    ///
    /// Trashed notebooks are left out: they are not in the library any more, and
    /// pushing one would put it straight back into the ClassNotes tab. So are
    /// remote-only ones: the server is where they come FROM, and echoing them
    /// back told it they had one page — this device's guess, since it has none.
    public func fullSnapshot() -> (notebooks: [NotebookSnapshot], shelves: [ShelfSnapshot]) {
        let notebooks = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        return (notebooks.filter { !$0.isTrashed && !$0.isRemoteOnly }.map(snapshot), shelves.map(snapshot))
    }

    /// Every notebook the library lists as THIS device's, and those in the trash.
    ///
    /// Remote-only rows are left out: their package was never here, so a copy
    /// of one in iCloud that this device's ledger says it sent is a stand-in an
    /// older build uploaded (`DocumentStore.isStandIn`), and sync moves it out
    /// of the shared folder instead of bringing it back down. A real package
    /// from another device has no ledger entry here and is still taken in.
    public func rowIDs() -> (all: Set<UUID>, trashed: Set<UUID>) {
        let rows = ((try? context.fetch(FetchDescriptor<Notebook>())) ?? []).filter { !$0.isRemoteOnly }
        return (Set(rows.map(\.id)), Set(rows.filter(\.isTrashed).map(\.id)))
    }

    /// Takes another device's description of a notebook when it is NEWER than
    /// this device's (`metadataRevisedAt`): title, cover, page defaults, shelf,
    /// tags, favourite, view-only and the trash. An older one changes nothing,
    /// and this device's description is written back over it.
    public func applySyncedInfo(_ info: NotebookInfo) {
        let rows = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        guard let notebook = rows.first(where: { $0.id == info.id }) else { return }
        let revised = info.revisedAt ?? info.updatedAt
        guard revised > notebook.metadataRevisedAt else {
            mirrorInfoSoon([notebook])
            return
        }
        notebook.title = info.title
        if !info.coverColorHex.isEmpty { notebook.coverColorHex = info.coverColorHex }
        notebook.coverDesignRaw = info.coverDesign
        notebook.showsCover = info.showsCover
        notebook.defaultTemplateRaw = info.defaultTemplate
        notebook.pageSizeRaw = info.pageSize
        notebook.orientationRaw = info.orientation
        notebook.paperColorHex = info.paperColorHex
        notebook.lineColorHex = info.lineColorHex
        notebook.lineSpacingSteps = info.lineSpacingSteps
        notebook.shelfID = shelf(for: info)
        notebook.isFavorite = info.isFavorite
        notebook.isViewOnly = info.isViewOnly
        notebook.deletedAt = info.deletedAt
        notebook.tags = info.tags ?? []
        notebook.metadataRevisedAt = revised
        notebook.updatedAt = max(notebook.updatedAt, info.updatedAt)
        try? context.save()
        mirrorInfoSoon([notebook])
        if notebook.isTrashed {
            sync?.deleteNotebook(id: notebook.id)
        } else {
            sync?.pushNotebook(snapshot(notebook))
        }
    }

    /// The content of these notebooks was just replaced by another device's:
    /// moved up the library, and the cover tile redrawn.
    public func markChangedElsewhere(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        let rows = ((try? context.fetch(FetchDescriptor<Notebook>())) ?? []).filter { wanted.contains($0.id) }
        for notebook in rows { notebook.updatedAt = .now }
        try? context.save()
    }

    /// Removed from iCloud by another device: to the trash here, never gone.
    public func trashRemovedElsewhere(_ ids: [UUID]) {
        let wanted = Set(ids)
        let rows = ((try? context.fetch(FetchDescriptor<Notebook>())) ?? []).filter { wanted.contains($0.id) }
        try? moveToTrash(rows)
    }

    /// The shelf a description names, created from it if this device doesn't
    /// have it (the same way a rebuilt library puts shelves back).
    private func shelf(for info: NotebookInfo) -> UUID? {
        guard let shelfID = info.shelfID else { return nil }
        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        if shelves.contains(where: { $0.id == shelfID }) { return shelfID }
        guard let name = info.shelfName else { return nil }
        context.insert(Shelf(
            id: shelfID, name: name, colorHex: info.shelfColorHex ?? ThemePreset.light.accent.hexString,
            symbolName: info.shelfSymbol ?? "bag", sortIndex: shelves.count
        ))
        return shelfID
    }
}
