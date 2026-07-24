import Foundation
import Observation
import SwiftData

/// Root dependency container, built once at app launch and injected through
/// the SwiftUI environment.
@MainActor
@Observable
public final class AppServices {
    /// Retained here on purpose: ModelContexts do NOT keep their container
    /// alive, and a deallocated container makes every store operation trap.
    public let modelContainer: ModelContainer
    public let documentStore: DocumentStore
    public let entitlements: EntitlementService
    public let themeService: ThemeService
    public let repository: NotebookRepository

    public init(modelContainer: ModelContainer, documentsRootURL: URL? = nil) {
        self.modelContainer = modelContainer
        let context = modelContainer.mainContext
        let store = DocumentStore(rootURL: documentsRootURL)
        let entitlements = EntitlementService()
        self.documentStore = store
        self.entitlements = entitlements
        self.themeService = ThemeService(context: context, entitlements: entitlements)
        self.repository = NotebookRepository(context: context, store: store, entitlements: entitlements)
    }

    /// Kick off async StoreKit work after launch.
    public func start() {
        Task {
            await entitlements.refreshEntitlements()
            await entitlements.loadProducts()
        }
    }
}
