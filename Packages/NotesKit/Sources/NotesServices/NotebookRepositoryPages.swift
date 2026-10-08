import Foundation
import NotesModels
import SwiftData

/// The library's side of moving pages between notebooks.
public extension NotebookRepository {

    /// Notebooks a page can be sent to from `notebookID`: live, on this device,
    /// editable, most recently used first. A remote-only row has no package to
    /// write into, and a view-only one is not to be changed.
    func pageDestinations(excluding notebookID: UUID) -> [Notebook] {
        let all = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        return all
            .filter { $0.id != notebookID && !$0.isTrashed && !$0.isRemoteOnly && !$0.isViewOnly }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Records that pages arrived in `notebookID`, so its library tile, its
    /// description and the ClassMate mirror all catch up.
    func pagesArrived(in notebookID: UUID) {
        let all = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        guard let notebook = all.first(where: { $0.id == notebookID }) else { return }
        touch(notebook)
    }
}
