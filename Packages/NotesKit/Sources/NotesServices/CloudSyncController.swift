import Foundation
import NotesModels
import Observation

/// The "Sync with iCloud" switch and everything behind it (D-003): when a pass
/// runs, which notebooks it must leave alone, and what it tells the library.
///
/// Off until the user turns it on. A pass runs at launch, on returning to the
/// app, a moment after a notebook closes, and every few minutes while the app
/// is open; passes never overlap, and one asked for during another runs once
/// it ends.
@MainActor
@Observable
public final class CloudSyncController {
    public enum Status: Equatable, Sendable {
        case off
        /// Not signed in to iCloud, or iCloud Drive is off for ClassNotes.
        case unavailable
        case syncing
        case upToDate(Date)
        /// Some notebooks couldn't sync this time; they are tried again.
        case partly(failed: Int, at: Date)
    }

    /// Whether this build can sync at all: it needs the iCloud container in
    /// its entitlements, which `CMCloudSync` in Info.plist says it has. Off,
    /// the switch isn't shown, so nobody is offered something that can't work.
    public let isSupported: Bool
    public private(set) var isEnabled: Bool
    public private(set) var status: Status
    /// Kept-both copies made by the last pass, for the library to point out.
    public private(set) var lastForked: [UUID] = []

    @ObservationIgnored private let engine: NotebookSync
    @ObservationIgnored private let repository: NotebookRepository
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var openNotebooks: Set<UUID> = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var runAgain = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    private static let enabledKey = "cloudSync.enabled.v1"
    /// How often a pass runs while the app is open.
    static let interval: Duration = .seconds(300)

    public init(
        store: DocumentStore, repository: NotebookRepository,
        drive: CloudDrive = ICloudDrive(), stateFolder: URL? = nil, defaults: UserDefaults = .standard,
        supported: Bool = CloudSyncController.buildSupportsSync
    ) {
        let folder = stateFolder ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassNotes/CloudSync", isDirectory: true)
        self.engine = NotebookSync(store: store, drive: drive, stateFolder: folder)
        self.repository = repository
        self.defaults = defaults
        self.isSupported = supported
        let enabled = supported && defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.status = enabled ? .syncing : .off
    }

    /// `CMCloudSync` in the app's Info.plist.
    public static var buildSupportsSync: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CMCloudSync") as? Bool ?? false
    }

    public func setEnabled(_ enabled: Bool) {
        guard isSupported, enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            ticker?.cancel()
            ticker = nil
            status = .off
        }
    }

    /// Begins syncing if it's on: a pass now, then one every `interval`.
    public func start() {
        guard isEnabled, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// The editor has this notebook open: a pass leaves it alone.
    public func opened(_ id: UUID) {
        openNotebooks.insert(id)
    }

    /// The editor closed it: sync it once its last save has landed.
    public func closed(_ id: UUID) {
        openNotebooks.remove(id)
        guard isEnabled else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.syncNow()
        }
    }

    /// Runs a pass now, or straight after the one running.
    public func syncNow() async {
        guard isEnabled else { return }
        if running {
            runAgain = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            runAgain = false
            await pass()
        } while runAgain && isEnabled
    }

    private func pass() async {
        status = .syncing
        let rows = repository.rowIDs()
        let outcome = await engine.pass(open: openNotebooks, rows: rows.all, trashed: rows.trashed)
        guard isEnabled else { return }
        if outcome.unavailable {
            status = .unavailable
            return
        }
        await apply(outcome)
        status = outcome.failed.isEmpty ? .upToDate(.now) : .partly(failed: outcome.failed.count, at: .now)
    }

    /// What a pass changed, told to the library.
    func apply(_ outcome: NotebookSync.Outcome) async {
        // New packages (from another device, or kept-both copies) become rows
        // the way any package without one does.
        if !outcome.adopted.isEmpty || !outcome.forked.isEmpty {
            _ = await repository.reconcileWithDisk()
        }
        for info in outcome.metadata { repository.applySyncedInfo(info) }
        repository.markChangedElsewhere(outcome.pulled)
        repository.trashRemovedElsewhere(outcome.removedElsewhere)
        if !outcome.forked.isEmpty { lastForked = outcome.forked }
    }
}
