import Foundation
import NotesModels
import os

private let syncLog = Logger(subsystem: "com.classmate.notes", category: "CloudSync")

/// What this device last agreed with the shared folder about each notebook:
/// the content fingerprint here and there at the last sync. Per device, never
/// synced itself.
struct SyncLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var local: String
        var cloud: String
        /// Removed from the shared folder by another device. The notebook went
        /// to the trash here instead of being destroyed, and is not uploaded
        /// again unless the user restores it.
        var removedElsewhere = false
    }
    var entries: [UUID: Entry] = [:]
}

/// Keeps notebooks the same on every device signed in to the same iCloud
/// (D-003), WITHOUT the shared folder ever becoming where notebooks live.
///
/// Every notebook stays a package on this device, with everything that keeps
/// it safe here (backups, quarantine, soft delete, the torture-tested store).
/// The shared folder is a mailbox: a pass compares each notebook's content
/// here and there with what they were at the last sync (`SyncLedger`), and:
/// - changed only here → it goes up, file by file;
/// - changed only there → it comes down, checked before it replaces anything,
///   and the notebook it replaces is kept (`replacedFolder`);
/// - changed in both places → BOTH are kept: the other device's version comes
///   in as its own notebook, "(other device)", and this one goes up. Merging
///   ink is never guessed at, and last-writer-wins is never acceptable for it.
/// A notebook open in the editor is left alone until it closes. Deletions only
/// ever move things to a trash: a notebook removed on another device goes to
/// this device's trash, and one purged here leaves the shared folder for a
/// holding folder kept for 30 days.
public actor NotebookSync {

    /// What one pass did, for the library to act on.
    public struct Outcome: Sendable, Equatable {
        public var unavailable = false
        public var pushed: [UUID] = []
        public var pulled: [UUID] = []
        /// New here, or repaired here: packages with no row yet, or a row
        /// whose package had gone missing.
        public var adopted: [UUID] = []
        /// The other device's version, kept as a new notebook beside this one.
        public var forked: [UUID] = []
        /// Removed on another device: move to this device's trash.
        public var removedElsewhere: [UUID] = []
        /// Descriptions from another device newer than this device's.
        public var metadata: [NotebookInfo] = []
        /// Open in the editor, or not downloaded yet: next time.
        public var deferred: [UUID] = []
        public var failed: [UUID] = []
    }

    /// The suffix a kept-both copy's title gets.
    public static let otherDeviceSuffix = " (other device)"
    /// How long a replaced notebook, or one purged here, is kept.
    public static let keepFor: TimeInterval = 30 * 24 * 3600

    let store: DocumentStore
    let drive: CloudDrive
    let stateFolder: URL
    var ledger: SyncLedger?
    /// Fingerprints of the shared copies, by the file stamp they were taken at.
    var cloudFingerprints: [UUID: (stamp: String, fingerprint: String)] = [:]

    /// `stateFolder`: this device's own record of the sync, and the notebooks
    /// a sync replaced.
    public init(store: DocumentStore, drive: CloudDrive, stateFolder: URL) {
        self.store = store
        self.drive = drive
        self.stateFolder = stateFolder
    }

    var ledgerURL: URL { stateFolder.appendingPathComponent("ledger.json") }
    public var replacedFolder: URL { stateFolder.appendingPathComponent("Replaced", isDirectory: true) }

    /// One pass over every notebook here and in the shared folder.
    ///
    /// - open: notebooks open in the editor, left alone.
    /// - rows: notebooks the library lists (live or in the trash).
    /// - trashed: those in the trash.
    public func pass(open: Set<UUID>, rows: Set<UUID>, trashed: Set<UUID>) async -> Outcome {
        var outcome = Outcome()
        guard let cloud = await drive.folder() else {
            outcome.unavailable = true
            return outcome
        }
        var context = Pass(cloud: cloud, rows: rows, trashed: trashed, ledger: loadLedger(), outcome: outcome)
        let local = Set(await store.packageIDs())
        let remote = Set(PackageFiles.packageIDs(in: cloud))
        for id in local.union(remote).sorted(by: { $0.uuidString < $1.uuidString }) {
            if open.contains(id) {
                context.outcome.deferred.append(id)
                continue
            }
            do {
                try await reconcile(id, hasLocal: local.contains(id), hasCloud: remote.contains(id), &context)
            } catch DocumentStore.SyncError.inUse {
                context.outcome.deferred.append(id)
            } catch {
                syncLog.error("Sync of a notebook failed: \(String(describing: error), privacy: .public)")
                context.outcome.failed.append(id)
            }
        }
        saveLedger(context.ledger)
        prune(replacedFolder)
        prune(cloud.deletingLastPathComponent().appendingPathComponent("Removed", isDirectory: true))
        return context.outcome
    }

    /// What one pass carries from notebook to notebook.
    struct Pass {
        let cloud: URL
        let rows: Set<UUID>
        let trashed: Set<UUID>
        var ledger: SyncLedger
        var outcome: Outcome

        func there(_ id: UUID) -> URL {
            cloud.appendingPathComponent("\(id.uuidString).\(DocumentStore.fileExtension)")
        }
    }

    // MARK: - One notebook

    private func reconcile(_ id: UUID, hasLocal: Bool, hasCloud: Bool, _ pass: inout Pass) async throws {
        if hasCloud, !(await drive.download(pass.there(id))) {
            pass.outcome.deferred.append(id)
            return
        }
        switch (hasLocal, hasCloud) {
        case (true, false): try await onlyHere(id, &pass)
        case (false, true): try await onlyThere(id, &pass)
        case (true, true): try await inBoth(id, &pass)
        case (false, false): return
        }
    }

    /// Here and not in the shared folder.
    private func onlyHere(_ id: UUID, _ pass: inout Pass) async throws {
        let entry = pass.ledger.entries[id]
        if let entry, !entry.removedElsewhere {
            // It was in the shared folder and isn't now: removed on another
            // device. To the trash here, never destroyed.
            pass.ledger.entries[id]?.removedElsewhere = true
            if !pass.trashed.contains(id) { pass.outcome.removedElsewhere.append(id) }
        } else if entry?.removedElsewhere == true, pass.trashed.contains(id) {
            return
        } else {
            // New here, or restored after another device removed it.
            try await send(id, &pass)
        }
    }

    /// In the shared folder and not here.
    private func onlyThere(_ id: UUID, _ pass: inout Pass) async throws {
        if pass.ledger.entries[id] == nil || pass.rows.contains(id) {
            // New from another device — or listed here with its package gone,
            // which the copy there puts right.
            let fingerprint = try await adopt(pass.there(id), as: id)
            pass.ledger.entries[id] = .init(local: fingerprint, cloud: fingerprint)
            pass.outcome.adopted.append(id)
        } else {
            // Synced before and purged here: out of the shared folder, into a
            // holding folder for 30 days.
            let removed = pass.cloud.deletingLastPathComponent()
                .appendingPathComponent("Removed", isDirectory: true)
                .appendingPathComponent("\(id.uuidString)-\(DocumentStore.fileStamp()).\(DocumentStore.fileExtension)")
            try CoordinatedFiles.move(pass.there(id), to: removed)
            pass.ledger.entries[id] = nil
        }
    }

    /// In both: whichever side changed since they last agreed wins, and if
    /// both did, both are kept.
    private func inBoth(_ id: UUID, _ pass: inout Pass) async throws {
        let there = pass.there(id)
        guard let here = await store.contentFingerprint(id) else { throw DocumentStore.SyncError.missing }
        let away = try cloudFingerprint(id, at: there)
        let entry = pass.ledger.entries[id]
        if here == away {
            pass.ledger.entries[id] = .init(local: here, cloud: away)
            try reconcileDescriptions(id, there: there, outcome: &pass.outcome)
            return
        }
        let changedHere = entry.map { $0.local != here } ?? true
        let changedThere = entry.map { $0.cloud != away } ?? true
        if changedHere && !changedThere {
            try await send(id, &pass)
        } else if changedThere && !changedHere {
            let before = Self.readInfo(at: store.documentURL(for: id))
            let fingerprint = try await pull(there, into: id)
            pass.ledger.entries[id] = .init(local: fingerprint, cloud: fingerprint)
            pass.outcome.pulled.append(id)
            try await keepNewerDescription(id, before: before, there: there, outcome: &pass.outcome)
        } else {
            // Both changed since they last agreed. Keep both.
            let copy = try await fork(there)
            pass.outcome.forked.append(copy)
            try await send(copy, &pass, counted: false)
            try await send(id, &pass)
        }
    }

    /// Up, with its description, and recorded as agreed.
    private func send(_ id: UUID, _ pass: inout Pass, counted: Bool = true) async throws {
        let there = pass.there(id)
        let fingerprint = try await push(id, to: there)
        pass.ledger.entries[id] = .init(local: fingerprint, cloud: fingerprint)
        if counted { pass.outcome.pushed.append(id) }
        try reconcileDescriptions(id, there: there, outcome: &pass.outcome)
    }
}

extension JSONDecoder {
    /// `info.json` as `DocumentStore` writes it.
    static var syncInfo: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var syncInfo: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
