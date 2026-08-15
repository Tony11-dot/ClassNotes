import ClassMateTheme
import Foundation
import NotesModels
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
    public let aiProvider: NovaProviderRouter
    /// User-uploaded fonts (OTF/TTF) for beautify + text, registered at launch.
    public let fontStore: CustomFontStore
    /// Mirrors the local library up to the ClassMate backend so the ClassMate
    /// "ClassNotes" tab shows the user's real notebooks.
    public let sync: SyncService
    /// Saved NOVA conversations, per notebook.
    public let novaChats: NovaChatStore
    /// How the tools are tuned and what the Pencil's gestures do — saved, and
    /// carried between the user's own devices.
    public let settings: SettingsStore
    /// Reads handwriting into text so notebooks can be searched by what's
    /// written in them, not only by what they're called.
    public let searchIndexer: SearchIndexer

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
        self.settings = SettingsStore(context: context)
        self.repository = NotebookRepository(
            context: context, store: store, entitlements: entitlements, sync: sync
        )
        self.aiProvider = NovaProviderRouter(keychain: keychain)
        self.fontStore = CustomFontStore()
        self.searchIndexer = SearchIndexer(store: store)
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
        // Every settled settings change goes up to the account, so the user's
        // other device gets it. Wired before the first pull so a change made
        // during launch isn't dropped.
        settings.onChange = { [sync] snapshot in
            sync.pushSettings(snapshot)
        }
        Task {
            await auth.restore()
            await entitlements.refreshEntitlements()
            await entitlements.loadProducts()
            await syncSettings()
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
        Task { await runMaintenance() }
    }

    /// Housekeeping that has nothing to do with the account, kept off the sync
    /// task so a signed-out device still does it.
    ///
    /// Reading the library for search runs LAST and at low priority: it is the
    /// most expensive thing the app does at launch and the least urgent, and it
    /// must never be what makes the first page slow to open.
    private func runMaintenance() async {
        await repository.purgeExpiredTrash()
        let targets = repository.searchTargets()
        guard !targets.isEmpty else { return }
        await Task(priority: .background) { [searchIndexer] in
            await searchIndexer.indexAll(targets)
        }.value
    }

    /// Reconciles this device's setup with the account's.
    ///
    /// Same shape as the library: PULL first, and let the newer revision win. A
    /// second device that pushed first would send its factory defaults over the
    /// setup the user spent an evening on — which is the one outcome that would
    /// make the whole feature worse than not having it.
    private func syncSettings() async {
        let mine = settings.snapshot(
            themeSelection: themeService.selection.rawValue,
            paperTone: themeService.paperTone.rawValue
        )
        guard let remote = await sync.fetchSettings() else {
            sync.pushSettings(mine)
            return
        }
        if settings.apply(remote: remote) {
            // The theme travels with the tools: "everything I set up" includes
            // which theme and paper the user chose, not just their pens.
            if let selection = ThemeSelection(rawValue: remote.themeSelection) {
                themeService.selection = selection
            }
            if let tone = PaperTone(rawValue: remote.paperTone) {
                themeService.paperTone = tone
            }
        } else if DeviceSettings.newer(mine, remote) == mine {
            sync.pushSettings(mine)
        }
    }
}
