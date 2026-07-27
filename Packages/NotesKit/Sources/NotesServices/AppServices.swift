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
    /// User-uploaded fonts (OTF/TTF) for beautify + text, registered at launch.
    public let fontStore: CustomFontStore
    /// Mirrors the local library up to the ClassMate backend so the ClassMate
    /// "ClassNotes" tab shows the user's real notebooks.
    public let sync: SyncService
    /// Saved NOVA conversations, per notebook.
    public let novaChats: NovaChatStore

    public init(modelContainer: ModelContainer, documentsRootURL: URL? = nil) {
        self.modelContainer = modelContainer
        let context = modelContainer.mainContext
        let store = DocumentStore(rootURL: documentsRootURL)
        let entitlements = EntitlementService()
        let keychain: any SecretStore = KeychainStore()
        let auth = AuthService(keychain: keychain)
        let sync = SyncService(client: ClassMateAPIClient(), auth: auth, store: store)
        self.documentStore = store
        self.entitlements = entitlements
        self.keychain = keychain
        self.auth = auth
        self.sync = sync
        self.themeService = ThemeService(context: context, entitlements: entitlements)
        self.novaChats = NovaChatStore(context: context)
        self.repository = NotebookRepository(
            context: context, store: store, entitlements: entitlements, sync: sync
        )
        self.aiProvider = GroqProvider(keychain: keychain)
        self.fontStore = CustomFontStore()
    }

    // MARK: - Groq key (entered in Settings, stored in Keychain)

    public var groqAPIKey: String {
        get { keychain.get(.groqAPIKey) ?? "" }
        set { keychain.set(newValue.trimmingCharacters(in: .whitespaces), for: .groqAPIKey) }
    }

    public func makeNovaConversation() -> NovaConversation {
        NovaConversation(provider: aiProvider)
    }

    /// Ask NOVA (server-side, keyless) to tidy up the student's own note text.
    /// Returns the cleaned text, or nil if signed out / the request fails — the
    /// caller falls back to the raw OCR text so beautify still works offline.
    public func beautifyText(_ text: String) async -> String? {
        guard let token = auth.token, !token.isEmpty else { return nil }
        let cleaned = try? await ClassMateAPIClient().beautify(text: text, token: token)
        let trimmed = cleaned?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Kick off async work after launch: entitlements, products, and restoring
    /// the ClassMate session.
    public func start() {
        Task {
            await auth.restore()
            await entitlements.refreshEntitlements()
            await entitlements.loadProducts()
            // PULL first: notebooks the user deleted or renamed in the ClassMate
            // ClassNotes tab. Pushing first would send this device's stale copy
            // back over those edits and undo them.
            await sync.pullRemoteChanges { [repository] changes in
                await repository.applyRemoteChanges(changes)
            }
            // Then reconcile the whole local library up to the backend (first run
            // + any missed per-edit pushes). No-ops when signed out
            // (SyncService checks the token).
            let snapshot = repository.fullSnapshot()
            sync.pushAll(notebooks: snapshot.notebooks, shelves: snapshot.shelves)
        }
    }
}
