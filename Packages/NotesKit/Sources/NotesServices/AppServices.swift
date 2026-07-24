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
    public let auth: AuthService
    public let keychain: any SecretStore
    public let aiProvider: GroqProvider

    public init(modelContainer: ModelContainer, documentsRootURL: URL? = nil) {
        self.modelContainer = modelContainer
        let context = modelContainer.mainContext
        let store = DocumentStore(rootURL: documentsRootURL)
        let entitlements = EntitlementService()
        let keychain: any SecretStore = KeychainStore()
        self.documentStore = store
        self.entitlements = entitlements
        self.keychain = keychain
        self.themeService = ThemeService(context: context, entitlements: entitlements)
        self.repository = NotebookRepository(context: context, store: store, entitlements: entitlements)
        self.auth = AuthService(keychain: keychain)
        self.aiProvider = GroqProvider(keychain: keychain)
    }

    // MARK: - Groq key (entered in Settings, stored in Keychain)

    public var groqAPIKey: String {
        get { keychain.get(.groqAPIKey) ?? "" }
        set { keychain.set(newValue.trimmingCharacters(in: .whitespaces), for: .groqAPIKey) }
    }

    public func makeNovaConversation() -> NovaConversation {
        NovaConversation(provider: aiProvider)
    }

    /// Kick off async work after launch: entitlements, products, and restoring
    /// the ClassMate session.
    public func start() {
        Task {
            await auth.restore()
            await entitlements.refreshEntitlements()
            await entitlements.loadProducts()
        }
    }
}
