import Foundation
import NotesModels

/// What the store does for iCloud sync (D-003). Each runs on the store's
/// actor, so a copy taken or put in place never interleaves with a save.
extension DocumentStore {

    public enum SyncError: Error, Sendable, Equatable {
        /// A copy from another device whose manifest doesn't read. It is never
        /// put in place of a notebook that does.
        case unreadableCopy
        case missing
        /// Open in the editor: replaced after it closes, never under it.
        case inUse
    }

    /// The editor has this notebook open. Called on the store BEFORE the
    /// editor loads anything, so a replacement either lands first (and is what
    /// loads) or is refused: there is no moment where an editor holds the old
    /// notebook and would later save it over the new one.
    public func beginEditing(_ id: UUID) {
        editing[id, default: 0] += 1
    }

    public func endEditing(_ id: UUID) {
        guard let count = editing[id] else { return }
        editing[id] = count > 1 ? count - 1 : nil
    }

    /// The notebook's travelling files, as they are right now, into a new
    /// folder at `destination`.
    public func exportPackage(_ id: UUID, to destination: URL) throws {
        let source = documentURL(for: id)
        guard FileManager.default.fileExists(atPath: source.path) else { throw SyncError.missing }
        try PackageFiles.copySynced(from: source, to: destination)
    }

    /// The fingerprint of the notebook's content (`PackageFiles.fingerprint`),
    /// re-hashed only when a content file changed size or date.
    public func contentFingerprint(_ id: UUID) -> String? {
        let package = documentURL(for: id)
        guard FileManager.default.fileExists(atPath: package.path) else { return nil }
        let stamp = PackageFiles.stamp(of: package)
        if let cached = fingerprintCache[id], cached.stamp == stamp { return cached.fingerprint }
        let fingerprint = PackageFiles.fingerprint(of: package)
        fingerprintCache[id] = (stamp, fingerprint)
        return fingerprint
    }

    /// Puts another device's copy of a notebook in place of this one.
    ///
    /// Checked first: a copy whose manifest won't read is refused and the
    /// notebook here is left exactly as it was. The notebook being replaced
    /// isn't deleted: it moves to `backups`, whole, so a sync that turns out
    /// wrong costs nothing that can't be put back. This device's own files
    /// (the search index, recovery copies) go with it; the index is rebuilt.
    public func replacePackage(_ id: UUID, with copy: URL, backups: URL) throws {
        guard editing[id] == nil else { throw SyncError.inUse }
        try validate(copy)
        let fm = FileManager.default
        let current = documentURL(for: id)
        var backup: URL?
        if fm.fileExists(atPath: current.path) {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let kept = backups.appendingPathComponent("\(id.uuidString)-\(Self.fileStamp()).\(Self.fileExtension)")
            try fm.moveItem(at: current, to: kept)
            backup = kept
        }
        do {
            try fm.moveItem(at: copy, to: current)
        } catch {
            if let backup { try? fm.moveItem(at: backup, to: current) }
            throw error
        }
        forgetCaches(for: id)
    }

    /// Takes in a notebook from another device as a NEW package (`id` must
    /// not exist here yet). Checked the same way.
    public func adoptPackage(_ copy: URL, as id: UUID) throws {
        try validate(copy)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: copy, to: documentURL(for: id))
    }

    private func validate(_ package: URL) throws {
        guard let data = try? Data(contentsOf: package.appendingPathComponent("manifest.json")),
              (try? decoder.decode(NotebookManifest.self, from: data)) != nil
        else { throw SyncError.unreadableCopy }
    }

    func forgetCaches(for id: UUID) {
        searchIndexCache[id] = nil
        fingerprintCache[id] = nil
    }
}
