import Foundation
import NotesModels
import SwiftData

/// Shelves inside shelves, and tags (D-007).
///
/// Both are local to this device for now: the ClassMate tab shows shelves flat
/// and has no tags, so neither travels in the library mirror. They do travel in
/// each package's `info.json` (tags) so a rebuilt library keeps them.
extension NotebookRepository {

    /// Stamps a change to what the library knows about these notebooks, so
    /// another device's copy of it is reconciled newest-wins (D-003).
    func revise(_ notebooks: [Notebook]) {
        let now = Date.now
        for notebook in notebooks { notebook.metadataRevisedAt = now }
    }

    /// The library's shelves as a tree.
    public func shelfTree() -> ShelfTree {
        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        return ShelfTree(shelves.map { ($0.id, $0.parentID) })
    }

    /// Puts `shelf` inside `parentID` (nil: the top of the library). Refused
    /// (false) when that would put a shelf inside itself.
    @discardableResult
    public func moveShelf(_ shelf: Shelf, under parentID: UUID?) -> Bool {
        guard shelfTree().canMove(shelf.id, under: parentID) else { return false }
        guard shelf.parentID != parentID else { return true }
        shelf.parentID = parentID
        try? context.save()
        return true
    }

    /// Replaces a notebook's tags, tidied (`NotebookTags`).
    public func setTags(_ tags: [String], for notebook: Notebook) {
        var tidy: [String] = []
        for tag in tags { tidy = NotebookTags.adding(tag, to: tidy) }
        guard tidy != notebook.tags else { return }
        notebook.tags = tidy
        revise([notebook])
        try? context.save()
        mirrorInfoSoon([notebook])
    }

    /// Adds one tag to several notebooks (a drop onto a tag, or a batch).
    public func addTag(_ tag: String, to notebooks: [Notebook]) {
        let changed = notebooks.filter { NotebookTags.adding(tag, to: $0.tags) != $0.tags }
        guard !changed.isEmpty else { return }
        for notebook in changed { notebook.tags = NotebookTags.adding(tag, to: notebook.tags) }
        revise(changed)
        try? context.save()
        mirrorInfoSoon(changed)
    }

    /// Takes a tag off every notebook that has it.
    public func removeTagEverywhere(_ tag: String) {
        let all = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        let changed = all.filter { NotebookTags.contains(tag, in: $0.tags) }
        guard !changed.isEmpty else { return }
        for notebook in changed { notebook.tags = NotebookTags.removing(tag, from: notebook.tags) }
        revise(changed)
        try? context.save()
        mirrorInfoSoon(changed)
    }
}
