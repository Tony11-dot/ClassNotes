import Foundation
import NotesModels
import NotesServices

/// How the editor's writes fail safely.
///
/// Every mutation used to be `manifest = try? await store.…`. A failed write —
/// a full disk is the realistic one — therefore set the manifest to nil, and the
/// notebook on screen went blank: every page gone, which to a student is
/// indistinguishable from "my notes were deleted". Element edits were `try?` as
/// well, so they stayed on screen while never reaching disk, and the next page
/// operation (which reads the manifest back from disk) quietly erased them.
///
/// Now: a failed manifest operation leaves the manifest the editor already has;
/// a failed element write is HELD and retried — before any other operation is
/// allowed to rewrite the manifest without it — and the editor shows what
/// happened in plain words until it has been saved.
extension NotebookEditorModel {

    /// Runs a store operation that returns the whole manifest. On failure the
    /// editor keeps what it has and reports it; returns whether it landed.
    @discardableResult
    func commit(_ operation: () async throws -> NotebookManifest) async -> Bool {
        // Anything still unsaved must land first: the operation rewrites the
        // manifest from disk, and would otherwise write over it.
        guard await flushUnsavedElements() else { return false }
        do {
            manifest = try await operation()
            clearProblemIfSaved()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Saves one page's element list, holding it until it reaches disk.
    func saveElements(_ elements: [PageElement], notebook: UUID, page: UUID) async {
        unsavedElements[page] = elements
        await flushUnsavedElements()
    }

    /// Writes every held element list. Returns false while anything is still
    /// unsaved.
    @discardableResult
    func flushUnsavedElements() async -> Bool {
        for (page, elements) in unsavedElements {
            do {
                _ = try await store.setElements(elements, notebook: notebookID, page: page)
                // Only clear what was written: a newer list held meanwhile stays.
                if unsavedElements[page] == elements { unsavedElements[page] = nil }
            } catch {
                report(error)
                return false
            }
        }
        clearProblemIfSaved()
        return true
    }

    /// Stores a media payload, reporting a failure instead of silently doing
    /// nothing when the user taps Insert.
    func storeMedia(_ data: Data, notebook: UUID, fileExtension: String) async -> String? {
        do {
            return try await store.saveMedia(data, notebook: notebook, fileExtension: fileExtension)
        } catch {
            report(error)
            return nil
        }
    }

    func report(_ error: Error) {
        saveProblem = SaveProblem(error)
        scheduleRetry()
    }

    private func clearProblemIfSaved() {
        guard unsavedElements.isEmpty else { return }
        saveProblem = nil
        retryTask?.cancel()
        retryTask = nil
    }

    /// Keeps trying every few seconds while something is held, so freeing up
    /// space is all the user has to do.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if self.unsavedElements.isEmpty {
                    // Only a one-off operation failed; nothing is held.
                    self.saveProblem = nil
                    self.retryTask = nil
                    return
                }
                if await self.flushUnsavedElements() { return }
            }
        }
    }

    // MARK: - Deleted pages

    /// Puts back the pages the last delete took, at their old positions.
    public func undoRecentDeletion() async {
        let ids = recentlyDeletedPages
        recentlyDeletedPages = []
        for id in ids.reversed() {
            await restorePage(id)
        }
    }

    /// The Undo toast timed out or was dismissed; the pages stay in the
    /// notebook's Recently Deleted list.
    public func dismissRecentDeletion() {
        recentlyDeletedPages = []
    }

    /// Pages deleted from this notebook that can still be restored.
    public func trashedPages() async -> [PageTrash.Entry] {
        await store.trashedPages(notebook: notebookID)
    }

    public func restorePage(_ pageID: UUID) async {
        let restored = await commit { [store, notebookID] in
            try await store.restorePage(notebook: notebookID, page: pageID)
        }
        if restored { focusedPageID = pageID }
    }

    /// Deletes trashed pages for good — the Recently Deleted list's own button.
    public func purgeTrashedPages(_ pageIDs: [UUID]) async {
        do {
            try await store.purgePages(pageIDs, notebook: notebookID)
        } catch {
            report(error)
        }
    }
}

/// What an import added, for the message the editor shows afterwards.
public struct ImportOutcome: Sendable, Equatable {
    public var firstPageID: UUID?
    /// Pages the source had that couldn't be read and were left out.
    public var skipped: Int
}

/// A running import's progress. `total` is 0 until the first page lands.
public struct ImportProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
}

extension NotebookEditorModel {

    /// Copies or moves pages to another notebook. Returns how many arrived, or
    /// nil if nothing could be written (the editor then says why).
    ///
    /// A move leaves the originals in this notebook's Recently Deleted, so
    /// sending pages to the wrong notebook is undone from there.
    public func transferPages(_ pageIDs: Set<UUID>, to target: UUID, move: Bool) async -> Int? {
        var added = 0
        let landed = await commit { [store, notebookID] in
            let result = try await store.transferPages(
                Array(pageIDs), from: notebookID, to: target, removingFromSource: move
            )
            added = result.added.count
            return result.source
        }
        guard landed else { return nil }
        if move, let focusedPageID, pageIDs.contains(focusedPageID), !pages.contains(where: { $0.id == focusedPageID }) {
            self.focusedPageID = manifest?.pages.first?.id
        }
        return added
    }
}
