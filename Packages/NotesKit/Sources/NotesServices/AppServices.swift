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
    /// Cached rendered pages for notebooks that exist on the account but have
    /// no local ink package on this device (see `Notebook.isRemoteOnly`).
    public let remoteNotebookCache: RemoteNotebookCache
    /// Saved NOVA conversations, per notebook.
    public let novaChats: NovaChatStore
    /// Whether this account has agreed to NOVA sending what they ask about to
    /// the AI provider. Nothing is sent without it.
    public let novaConsent: NovaConsent
    /// How the tools are tuned and what the Pencil's gestures do — saved, and
    /// carried between the user's own devices.
    public let settings: SettingsStore
    /// Reads handwriting into text so notebooks can be searched by what's
    /// written in them, not only by what they're called.
    public let searchIndexer: SearchIndexer
    /// Keeps notebooks the same on the user's devices through iCloud Drive,
    /// when they turn it on (D-003).
    public let cloudSync: CloudSyncController
    /// Crash, hang, launch and memory reports from MetricKit, kept on this
    /// device and shared only by the user (D-004).
    public let diagnostics: DiagnosticsLog
    @ObservationIgnored private let diagnosticsReceiver: DiagnosticsReceiver
    /// What opening the library database took, when it took more than opening
    /// it — see `ModelContainerFactory.makeRecovering`.
    public let storeRecovery: ModelContainerFactory.Recovery?
    /// Something the user should hear about once: notebooks put back in the
    /// library, or a library that had to be rebuilt. `nil` once dismissed.
    public var libraryNotice: LibraryNotice?
    /// The launch reconciliation, so everything that reads or syncs the library
    /// can wait for it.
    @ObservationIgnored private var reconciliation: Task<Void, Never>?

    public init(
        modelContainer: ModelContainer,
        documentsRootURL: URL? = nil,
        storeRecovery: ModelContainerFactory.Recovery? = nil
    ) {
        self.modelContainer = modelContainer
        self.storeRecovery = storeRecovery
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
        self.remoteNotebookCache = RemoteNotebookCache(client: ClassMateAPIClient())
        self.themeService = ThemeService(context: context, entitlements: entitlements)
        self.novaChats = NovaChatStore(context: context)
        self.novaConsent = NovaConsent { [auth] in auth.account?.id }
        let settings = SettingsStore(context: context)
        self.settings = settings
        let repository = NotebookRepository(
            context: context, store: store, entitlements: entitlements, sync: sync
        )
        self.repository = repository
        self.cloudSync = CloudSyncController(store: store, repository: repository)
        self.aiProvider = NovaProviderRouter(keychain: keychain)
        self.fontStore = CustomFontStore()
        let diagnostics = DiagnosticsLog()
        self.diagnostics = diagnostics
        self.diagnosticsReceiver = DiagnosticsReceiver(log: diagnostics)
        // Handwriting is read for search in the language the user writes in —
        // the same one beautification reads it in.
        self.searchIndexer = SearchIndexer(store: store) { @MainActor in
            settings.tools.beautify.language
        }
    }

    // MARK: - Groq key (entered in Settings, stored in Keychain)

    public var groqAPIKey: String {
        get { keychain.get(.groqAPIKey) ?? "" }
        set { keychain.set(newValue.trimmingCharacters(in: .whitespaces), for: .groqAPIKey) }
    }

    /// Every NOVA conversation shares the account's permission to send
    /// (`NovaConsent`); asked once, withdrawn in Settings.
    public func makeNovaConversation() -> NovaConversation {
        NovaConversation(provider: aiProvider, consent: novaConsent)
    }

    /// Kick off async work after launch: entitlements, products, and restoring
    /// the ClassMate session.
    public func start() {
        diagnosticsReceiver.start()
        // Every settled settings change goes up to the account, so the user's
        // other device gets it. Wired before the first pull so a change made
        // during launch isn't dropped.
        settings.onChange = { [sync] snapshot in
            sync.pushSettings(snapshot)
        }
        // Every package on disk is in the library BEFORE anything pulls, pushes
        // or purges it. Sign-in doesn't wait — the UI needs it at once.
        let reconciliation = Task { await reconcileLibrary() }
        self.reconciliation = reconciliation
        // Signing in mid-session (from Settings, or after working without an
        // account) syncs at once rather than at the next launch.
        auth.onSignIn = { [weak self] in
            guard let self else { return }
            Task { await self.syncAccount() }
        }
        Task {
            await auth.restore()
            await entitlements.refreshEntitlements()
            await entitlements.loadProducts()
            await syncAccount()
        }
        Task {
            await reconciliation.value
            // iCloud passes only once every package on disk has its row.
            cloudSync.start()
            await runMaintenance()
        }
    }

    /// Brings this device and the account into step: settings, then the
    /// library. No-ops without a session (SyncService checks the token).
    private func syncAccount() async {
        await syncSettings()
        await reconciliation?.value
        // PULL first — both halves, via `refreshRemoteLibrary`: notebooks
        // deleted/renamed/re-shelved elsewhere, and notebooks that exist on
        // the account but were created on another device. Pushing first
        // would send this device's stale copy back over those edits and
        // undo them.
        await refreshRemoteLibrary(force: true)
        // Then reconcile the whole local library up to the backend (first run
        // + any missed per-edit pushes).
        let snapshot = repository.fullSnapshot()
        sync.pushAll(notebooks: snapshot.notebooks, shelves: snapshot.shelves)
    }

    /// Puts any notebook package that has no row back in the library, and tells
    /// the user when that — or rebuilding the database itself — happened.
    private func reconcileLibrary() async {
        let result = await repository.reconcileWithDisk()
        libraryNotice = LibraryNotice(storeRecovery: storeRecovery, reconciliation: result)
    }

    /// When this last actually reached the network, so a foreground trigger
    /// and a pull-to-refresh moments apart don't both fire a request.
    @ObservationIgnored private var lastRemoteLibraryPull: Date?

    /// Re-pulls the account's library so BOTH directions of "the other
    /// device changed something" show up here: notebooks created elsewhere
    /// (`pullFullLibrary`) and notebooks deleted, renamed or re-shelved
    /// elsewhere (`pullRemoteChanges`) — same two calls `start()` makes at
    /// launch, in the same order (changes before discovery: a rename must
    /// land before a create-if-missing runs, or a stale title could race a
    /// pull that's mid-flight).
    ///
    /// Wiring only the discovery half in here — which is what this used to
    /// do — is why a delete or a shelve made on one device only ever reached
    /// the other after a full cold launch of the app: nothing foreground- or
    /// refresh-triggered ever re-checked `/classnotes/changes` at all.
    /// Throttled to once per 30s unless `force`d (the launch sequence forces
    /// it — there's nothing to throttle against yet).
    @discardableResult
    public func refreshRemoteLibrary(force: Bool = false) async -> Bool {
        if !force, let last = lastRemoteLibraryPull, Date().timeIntervalSince(last) < 30 {
            return false
        }
        lastRemoteLibraryPull = .now
        await sync.pullRemoteChanges { [repository] changes in
            await repository.applyRemoteChanges(changes)
        }
        await sync.pullFullLibrary { [repository, remoteNotebookCache] library in
            await repository.applyRemoteLibrary(library)
            for entry in library.notebooks {
                guard let id = UUID(uuidString: entry.id) else { continue }
                await remoteNotebookCache.cacheCover(entry.coverImage, for: id)
            }
        }
        return true
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

/// A one-time message about the library itself, written to answer the three
/// questions every error should: what happened, is my work safe, what now.
public struct LibraryNotice: Sendable, Equatable, Identifiable {
    public var title: String
    public var message: String
    public var id: String { title + message }

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// `nil` when there is nothing to say.
    init?(storeRecovery: ModelContainerFactory.Recovery?, reconciliation: LibraryReconciliation) {
        let found = reconciliation.recovered
        let notebooks = found == 1 ? "1 notebook" : "\(found) notebooks"
        switch storeRecovery {
        case .movedAside:
            self.init(
                title: "Your library was rebuilt",
                message: "ClassNotes couldn't open its library list, so it rebuilt it from the "
                    + "notebooks on this iPad (\(notebooks) found). Your notes are safe. "
                    + "Some settings, custom themes or NOVA chats may have been reset; the old "
                    + "copy was kept on this device."
            )
        case .inMemoryOnly:
            self.init(
                title: "Library changes won't be kept",
                message: "ClassNotes couldn't open its library list. Your notebooks are safe "
                    + "and you can keep writing, but renames, shelves and new settings made "
                    + "now won't be kept after you close the app. Restart ClassNotes to try again."
            )
        case nil:
            guard found > 0 else { return nil }
            self.init(
                title: found == 1 ? "A notebook was put back" : "Notebooks were put back",
                message: "ClassNotes found \(notebooks) on this iPad that "
                    + (found == 1 ? "wasn't" : "weren't")
                    + " showing in your library and put "
                    + (found == 1 ? "it" : "them")
                    + " back. Nothing was lost."
            )
        }
    }
}
