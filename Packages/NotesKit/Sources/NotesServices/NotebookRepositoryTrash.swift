import Foundation
import NotesModels
import SwiftData

/// Deleting, restoring and starring — the half of the library that is about not
/// losing things.
///
/// Split from `NotebookRepository` proper because the two halves answer
/// different questions: that file is "make me a notebook", this one is "I didn't
/// mean to delete that".
public extension NotebookRepository {
    // MARK: - Trash

    /// Takes a notebook out of the library WITHOUT destroying it.
    ///
    /// This is what every delete button in the app calls. The row and the whole
    /// document package are untouched — only `deletedAt` is set — so the ink is
    /// still there to be restored for `TrashPolicy.retention`. The server is told
    /// straight away, because as far as every other device is concerned this
    /// notebook is gone; restoring pushes it back.
    func moveToTrash(_ notebooks: [Notebook]) throws {
        guard !notebooks.isEmpty else { return }
        let now = Date.now
        for notebook in notebooks where !notebook.isTrashed {
            notebook.deletedAt = now
        }
        try context.save()
        for notebook in notebooks {
            sync?.deleteNotebook(id: notebook.id)
        }
    }

    func moveToTrash(_ notebook: Notebook) throws {
        try moveToTrash([notebook])
    }

    /// Puts trashed notebooks back in the library, and back on the server.
    func restore(_ notebooks: [Notebook]) throws {
        guard !notebooks.isEmpty else { return }
        for notebook in notebooks {
            notebook.deletedAt = nil
        }
        try context.save()
        for notebook in notebooks {
            sync?.pushNotebook(snapshot(notebook))
        }
    }

    func restore(_ notebook: Notebook) throws {
        try restore([notebook])
    }

    /// Everything currently in the trash, most recently deleted first.
    func trashedNotebooks() -> [Notebook] {
        let all = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        return all
            .filter(\.isTrashed)
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Destroys everything whose grace period has run out. Called once at launch.
    ///
    /// `now` is a parameter so the whole retention rule can be tested without
    /// waiting a month.
    @discardableResult
    func purgeExpiredTrash(now: Date = .now) async -> Int {
        let expired = trashedNotebooks().filter {
            TrashPolicy.isExpired(deletedAt: $0.deletedAt, now: now)
        }
        guard !expired.isEmpty else { return 0 }
        try? await purge(expired)
        return expired.count
    }

    /// Destroys a notebook for good — the row, and the ink on disk.
    ///
    /// Nothing is pushed: the server was told when it went into the trash, and a
    /// second delete for an id it has already forgotten is just noise.
    func purge(_ notebooks: [Notebook]) async throws {
        guard !notebooks.isEmpty else { return }
        for notebook in notebooks {
            try? await store.deleteDocument(id: notebook.id)
        }
        for notebook in notebooks {
            context.delete(notebook)
        }
        try context.save()
    }

    func purge(_ notebook: Notebook) async throws {
        try await purge([notebook])
    }

    func emptyTrash() async throws {
        try await purge(trashedNotebooks())
    }

    // MARK: - Favourites

    func setFavorite(_ isFavorite: Bool, for notebooks: [Notebook]) throws {
        guard !notebooks.isEmpty else { return }
        for notebook in notebooks {
            notebook.isFavorite = isFavorite
        }
        try context.save()
    }

    func toggleFavorite(_ notebook: Notebook) throws {
        try setFavorite(!notebook.isFavorite, for: [notebook])
    }

}
