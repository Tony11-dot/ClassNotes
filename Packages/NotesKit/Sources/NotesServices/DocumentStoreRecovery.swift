import Foundation
import NotesModels

/// The parts of the store whose only job is that nothing is ever lost: keeping
/// damaged manifests, the per-notebook page trash, and the package's own
/// description of itself (`info.json`) that the library is rebuilt from.
extension DocumentStore {

    // MARK: - Manifest recovery

    /// Moves an unreadable manifest out of the way, keeping it for good. Moving
    /// (not copying) matters: `writeManifest` turns whatever `manifest.json` is
    /// into the backup, and that must never be the damaged file.
    func quarantineManifest(notebook id: UUID) {
        let target = documentURL(for: id)
            .appendingPathComponent("manifest.unreadable-\(Self.fileStamp()).json")
        try? FileManager.default.moveItem(at: manifestURL(for: id), to: target)
    }

    /// The last-known-good manifest, read leniently if it has to be.
    func decodedBackup(notebook id: UUID) -> NotebookManifest? {
        guard let data = try? Data(contentsOf: manifestBackupURL(for: id)) else { return nil }
        return (try? decoder.decode(NotebookManifest.self, from: data)) ?? salvage(data)
    }

    /// Everything in a damaged manifest that still decodes, page by page and
    /// element by element.
    func salvage(_ data: Data) -> NotebookManifest? {
        let salvager = JSONDecoder()
        salvager.dateDecodingStrategy = .iso8601
        salvager.userInfo[.manifestSalvage] = true
        return try? salvager.decode(NotebookManifest.self, from: data)
    }

    /// The fuller of what a damaged manifest still holds and the backup. The
    /// salvage is the newer of the two, so it wins a tie; the backup wins when
    /// the damage cost pages, because a page lost from the list is a page the
    /// user can't see (its elements, template and position with it).
    func bestRecovery(salvaging damaged: Data, notebook id: UUID) -> NotebookManifest? {
        let candidates = [salvage(damaged), decodedBackup(notebook: id)].compactMap { $0 }
        guard var best = candidates.first else { return nil }
        for candidate in candidates.dropFirst() where candidate.pages.count > best.pages.count {
            best = candidate
        }
        return best
    }

    /// A manifest written by a NEWER build may hold fields this build drops on
    /// its first rewrite. Its original bytes are kept once, beside it, so going
    /// back to the newer build loses nothing it had written.
    func preserveIfNewer(_ manifest: NotebookManifest, original: Data, notebook id: UUID) {
        guard manifest.version > NotebookManifest.currentVersion else { return }
        let url = documentURL(for: id).appendingPathComponent("manifest.v\(manifest.version).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? original.write(to: url, options: .atomic)
    }

    // MARK: - Page trash

    func pageTrashURL(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("trash.json")
    }

    func pageTrash(for id: UUID) -> PageTrash {
        guard let data = try? Data(contentsOf: pageTrashURL(for: id)),
              let trash = try? decoder.decode(PageTrash.self, from: data) else { return PageTrash() }
        return trash
    }

    func writePageTrash(_ trash: PageTrash, for id: UUID) throws {
        if trash.entries.isEmpty {
            try? FileManager.default.removeItem(at: pageTrashURL(for: id))
            return
        }
        try encoder.encode(trash).write(to: pageTrashURL(for: id), options: .atomic)
    }

    /// A page the manifest lists as LIVE is not deleted, whatever the trash
    /// says — and its ink must be where a live page's ink is read from.
    ///
    /// Two ways to get here: a delete cut off after its trash entry but before
    /// the manifest (the blob never moved), and a damaged manifest replaced by
    /// its backup straight after a delete — the backup still lists the page,
    /// but its ink had already moved to `.drawing.deleted`. Without this the
    /// page came back BLANK, and in the same session every save to it went
    /// on into the trash, because its id was still tombstoned.
    func reviveLivePagesInTrash(_ liveIDs: [UUID], notebook id: UUID) {
        var trash = pageTrash(for: id)
        let live = Set(liveIDs)
        let revived = trash.entries.map(\.id).filter(live.contains)
        guard !revived.isEmpty else { return }
        let fm = FileManager.default
        for page in revived {
            let liveURL = pageURL(notebook: id, page: page)
            let trashedURL = trashedPageURL(notebook: id, page: page)
            // Only into an empty place: ink already at the live path is newer
            // than the trashed copy, which then stays where it is, untouched.
            if !fm.fileExists(atPath: liveURL.path), fm.fileExists(atPath: trashedURL.path) {
                try? fm.moveItem(at: trashedURL, to: liveURL)
            }
            deletedPageIDs.remove(page)
        }
        trash.entries.removeAll { live.contains($0.id) }
        try? writePageTrash(trash, for: id)
    }

    /// Deleted pages still recoverable, most recently deleted first. A page
    /// that is live again (a delete cut off before the manifest was written)
    /// is not listed — it isn't deleted.
    public func trashedPages(notebook id: UUID) -> [PageTrash.Entry] {
        let live = Set(((try? manifest(for: id))?.pages ?? []).map(\.id))
        return pageTrash(for: id).entries
            .filter { !live.contains($0.id) }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Puts a deleted page back where it was, with its ink, elements and media.
    ///
    /// The blob moves back first: a crash after that leaves the page still in
    /// the trash (and still skipped by the orphan scan) with its ink in place —
    /// restorable again, never a phantom page.
    @discardableResult
    public func restorePage(notebook id: UUID, page: UUID) throws -> NotebookManifest {
        // Manifest first: loading it can tidy the trash, and the copy of the
        // trash written back below must be the tidied one.
        var current = try manifest(for: id)
        var trash = pageTrash(for: id)
        guard let entry = trash.entries.first(where: { $0.id == page }) else { return current }
        let fm = FileManager.default
        let live = pageURL(notebook: id, page: page)
        let trashed = trashedPageURL(notebook: id, page: page)
        if fm.fileExists(atPath: trashed.path) {
            try? fm.removeItem(at: live)
            try fm.moveItem(at: trashed, to: live)
        }
        deletedPageIDs.remove(page)
        if !current.pages.contains(where: { $0.id == page }) {
            let index = min(max(0, entry.index), current.pages.count)
            current.pages.insert(entry.page, at: index)
        }
        try writeManifest(current, for: id)
        trash.entries.removeAll { $0.id == page }
        try writePageTrash(trash, for: id)
        return current
    }

    /// Removes trashed pages whose grace period has run out. Called when a
    /// notebook is opened, so it costs nothing at launch.
    @discardableResult
    public func purgeExpiredPages(notebook id: UUID, now: Date = .now) throws -> Int {
        let expired = pageTrash(for: id).entries
            .filter { TrashPolicy.isExpired(deletedAt: $0.deletedAt, now: now) }
            .map(\.id)
        guard !expired.isEmpty else { return 0 }
        try purgePages(expired, notebook: id)
        return expired.count
    }

    /// Destroys trashed pages for good: their ink, and any media nothing else
    /// still uses. A duplicate keeps its source's media filenames, so a file is
    /// removed only once no live page and no other trashed page references it.
    public func purgePages(_ ids: [UUID], notebook id: UUID) throws {
        let livePages = (try? manifest(for: id))?.pages ?? []
        var trash = pageTrash(for: id)
        let purging = trash.entries.filter { ids.contains($0.id) }
        guard !purging.isEmpty else { return }
        let fm = FileManager.default
        let liveIDs = Set(livePages.map(\.id))
        // Ink first, then the trash entry: in the other order, a blob that a
        // crash had left live-named would be re-adopted as a phantom page.
        for entry in purging {
            try? fm.removeItem(at: trashedPageURL(notebook: id, page: entry.id))
            if !liveIDs.contains(entry.id) {
                try? fm.removeItem(at: pageURL(notebook: id, page: entry.id))
            }
        }
        trash.entries.removeAll { ids.contains($0.id) }
        try writePageTrash(trash, for: id)
        forgetInBackup(purging.map(\.id), notebook: id)

        var stillNeeded = Set<String>()
        for page in livePages + trash.entries.map(\.page) {
            stillNeeded.formUnion(mediaFilenames(of: page))
        }
        for entry in purging {
            for filename in mediaFilenames(of: entry.page) where !stillNeeded.contains(filename) {
                try? fm.removeItem(at: mediaURL(notebook: id, filename: filename))
            }
        }
    }

    /// A purged page must not survive in the manifest BACKUP either. Straight
    /// after a delete the backup is the manifest from before it, which still
    /// lists the page — so a damaged manifest replaced by that backup brought a
    /// purged page back, blank (its ink was gone) and with elements whose
    /// media might have been swept. Found by the torture test, not by hand.
    func forgetInBackup(_ purged: [UUID], notebook id: UUID) {
        guard var backup = decodedBackup(notebook: id) else { return }
        let before = backup.pages.count
        backup.pages.removeAll { purged.contains($0.id) }
        guard backup.pages.count != before else { return }
        try? encoder.encode(backup).write(to: manifestBackupURL(for: id), options: .atomic)
    }

    // MARK: - The package's own description

    public nonisolated func infoURL(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("info.json")
    }

    /// Writes the notebook's library metadata into its package. A no-op for a
    /// notebook with no package (a remote-only one) — this must never be what
    /// creates a package — and when nothing changed.
    public func writeInfo(_ info: NotebookInfo) throws {
        guard FileManager.default.fileExists(atPath: documentURL(for: info.id).path) else { return }
        let data = try encoder.encode(info)
        let url = infoURL(for: info.id)
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    public func info(for id: UUID) -> NotebookInfo? {
        guard let data = try? Data(contentsOf: infoURL(for: id)) else { return nil }
        return try? decoder.decode(NotebookInfo.self, from: data)
    }

    /// Every notebook package on disk — anything that holds a manifest, its
    /// backup, a description or a pages folder. An empty folder is not a
    /// notebook.
    public func packageIDs() -> [UUID] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        )) ?? []
        return contents.compactMap { url in
            guard url.pathExtension == Self.fileExtension,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            let markers = [
                manifestURL(for: id), manifestBackupURL(for: id),
                infoURL(for: id), pagesDirectory(for: id)
            ]
            return markers.contains { fm.fileExists(atPath: $0.path) } ? id : nil
        }
    }

    /// When the package was first written — the best creation date a notebook
    /// rebuilt without its own description can get.
    public func packageCreatedAt(id: UUID) -> Date? {
        try? documentURL(for: id).resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
