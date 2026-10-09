import Foundation
import NotesModels

/// How `NotebookSync` moves a notebook: up, down, as a kept-both copy, and its
/// description; and the files it keeps for itself.
extension NotebookSync {

    /// Up: the notebook's content as it is here, written over the shared copy
    /// file by file. The description is left to `reconcileDescriptions`, so a
    /// rename made on the other device isn't overwritten by an older title
    /// riding along with new ink. Returns the content fingerprint that went up.
    func push(_ id: UUID, to there: URL) async throws -> String {
        let staging = scratch()
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        try await store.exportPackage(id, to: staging)
        try CoordinatedFiles.write(there) { url in
            try PackageFiles.mirror(from: staging, to: url, leaving: ["info.json"])
        }
        return PackageFiles.fingerprint(of: staging)
    }

    func cloudFingerprint(_ id: UUID, at there: URL) throws -> String {
        try CoordinatedFiles.read(there) { url in
            let stamp = PackageFiles.stamp(of: url)
            if let cached = cloudFingerprints[id], cached.stamp == stamp { return cached.fingerprint }
            let fingerprint = PackageFiles.fingerprint(of: url)
            cloudFingerprints[id] = (stamp, fingerprint)
            return fingerprint
        }
    }

    /// Down, over a notebook that exists here.
    func pull(_ there: URL, into id: UUID) async throws -> String {
        let staging = try copyOut(there)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        let fingerprint = PackageFiles.fingerprint(of: staging)
        try await store.replacePackage(id, with: staging, backups: replacedFolder)
        return fingerprint
    }

    /// Down, as a notebook that doesn't exist here.
    func adopt(_ there: URL, as id: UUID) async throws -> String {
        let staging = try copyOut(there)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        let fingerprint = PackageFiles.fingerprint(of: staging)
        if await store.documentExists(id: id) {
            try await store.replacePackage(id, with: staging, backups: replacedFolder)
        } else {
            try await store.adoptPackage(staging, as: id)
        }
        return fingerprint
    }

    /// The other device's version, as a new notebook here.
    func fork(_ there: URL) async throws -> UUID {
        let staging = try copyOut(there)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        let copy = UUID()
        let infoURL = staging.appendingPathComponent("info.json")
        if let data = try? Data(contentsOf: infoURL),
           var info = try? JSONDecoder.syncInfo.decode(NotebookInfo.self, from: data) {
            info.id = copy
            info.title += Self.otherDeviceSuffix
            info.revisedAt = .now
            try JSONEncoder.syncInfo.encode(info).write(to: infoURL, options: .atomic)
        }
        try await store.adoptPackage(staging, as: copy)
        return copy
    }

    /// The descriptions, newest wins: the title, cover, shelf, tags, trash.
    func reconcileDescriptions(_ id: UUID, there: URL, outcome: inout Outcome) throws {
        let away = try CoordinatedFiles.read(there.appendingPathComponent("info.json")) { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.syncInfo.decode(NotebookInfo.self, from: $0) }
        }
        // The store reads its own description.
        let hereURL = store.documentURL(for: id).appendingPathComponent("info.json")
        let here = (try? Data(contentsOf: hereURL)).flatMap { try? JSONDecoder.syncInfo.decode(NotebookInfo.self, from: $0) }
        let hereStamp = here?.revisedAt ?? .distantPast
        let awayStamp = away?.revisedAt ?? .distantPast
        if let away, awayStamp > hereStamp {
            outcome.metadata.append(away)
        } else if here != nil, hereStamp > awayStamp {
            try CoordinatedFiles.write(there.appendingPathComponent("info.json"), options: .forReplacing) { url in
                let data = try Data(contentsOf: hereURL)
                try data.write(to: url, options: .atomic)
            }
        }
    }

    /// After new content came down with the other device's description: if
    /// this device's description was the newer one (renamed here, written on
    /// there), it stays and goes up in the same pass; otherwise the one that
    /// came down is for the library to take.
    func keepNewerDescription(
        _ id: UUID, before: NotebookInfo?, there: URL, outcome: inout Outcome
    ) async throws {
        let arrived = Self.readInfo(at: store.documentURL(for: id))
        if let before, (before.revisedAt ?? .distantPast) > (arrived?.revisedAt ?? .distantPast) {
            try await store.writeInfo(before)
            let data = try JSONEncoder.syncInfo.encode(before)
            try CoordinatedFiles.write(there.appendingPathComponent("info.json"), options: .forReplacing) { url in
                try data.write(to: url, options: .atomic)
            }
        } else if let arrived {
            outcome.metadata.append(arrived)
        }
    }

    static func readInfo(at package: URL) -> NotebookInfo? {
        (try? Data(contentsOf: package.appendingPathComponent("info.json")))
            .flatMap { try? JSONDecoder.syncInfo.decode(NotebookInfo.self, from: $0) }
    }

    // MARK: - Files

    /// A copy of the shared package's travelling files, taken under
    /// coordination, in a scratch folder.
    func copyOut(_ there: URL) throws -> URL {
        let staging = scratch()
        try CoordinatedFiles.read(there) { url in try PackageFiles.copySynced(from: url, to: staging) }
        return staging
    }

    func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-sync-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("package.\(DocumentStore.fileExtension)", isDirectory: true)
    }

    func loadLedger() -> SyncLedger {
        if let ledger { return ledger }
        let loaded = (try? Data(contentsOf: ledgerURL)).flatMap { try? JSONDecoder().decode(SyncLedger.self, from: $0) }
        return loaded ?? SyncLedger()
    }

    func saveLedger(_ new: SyncLedger) {
        ledger = new
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(new) { try? data.write(to: ledgerURL, options: .atomic) }
    }

    /// How many replaced copies of one notebook are kept. A notebook synced
    /// every few minutes while it's written on elsewhere would otherwise keep a
    /// whole copy per pass and fill the device.
    public static let copiesKept = 2

    /// Removes kept copies older than `keepFor`, and all but the newest
    /// `copiesKept` of each notebook. Names are "<id>-<stamp>.cmnote", and the
    /// stamp sorts by time.
    func prune(_ folder: URL) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted(by: >)
        var keptPerNotebook: [Substring: Int] = [:]
        for name in names {
            let url = folder.appendingPathComponent(name)
            let notebook = name.prefix(36)
            keptPerNotebook[notebook, default: 0] += 1
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .now
            if keptPerNotebook[notebook, default: 0] > Self.copiesKept || Date.now.timeIntervalSince(modified) > Self.keepFor {
                try? fm.removeItem(at: url)
            }
        }
    }
}
