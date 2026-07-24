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

    public init(context: ModelContext, store: DocumentStore, entitlements: EntitlementService) {
        self.context = context
        self.store = store
        self.entitlements = entitlements
    }

    public func canCreateNotebook(currentCount: Int) -> Bool {
        entitlements.canCreateNotebook(currentCount: currentCount)
    }

    @discardableResult
    public func createNotebook(
        title: String,
        coverColor: ThemeColor,
        template: PageTemplate
    ) async throws -> Notebook {
        let notebook = Notebook(
            title: title.isEmpty ? "Untitled" : title,
            coverColorHex: coverColor.hexString,
            defaultTemplate: template
        )
        try await store.createDocument(id: notebook.id, firstPageTemplate: template)
        context.insert(notebook)
        try context.save()
        return notebook
    }

    public func rename(_ notebook: Notebook, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notebook.title = trimmed
        notebook.updatedAt = .now
        try context.save()
    }

    public func delete(_ notebook: Notebook) async throws {
        try await store.deleteDocument(id: notebook.id)
        context.delete(notebook)
        try context.save()
    }

    public func touch(_ notebook: Notebook) {
        notebook.updatedAt = .now
        try? context.save()
    }
}
