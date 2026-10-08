import Foundation
import NotesModels

/// What the ClassMate mirror last ACCEPTED for one notebook: a fingerprint per
/// page position, and the page count.
///
/// Closing the editor used to render EVERY page of the notebook on the main
/// thread and upload all of them, every time — a 200-page notebook froze the
/// library for seconds after one stroke on one page, and re-sent hundreds of
/// unchanged images. The server keys pages by index (upsert, then prune past
/// `pageCount`), so only the positions whose content changed need sending.
///
/// Derived data in Caches: if it's purged, the next close simply pushes the
/// whole notebook once. Scoped to the account, because a different account has
/// a different (empty) mirror.
public struct PageSyncLedger: Codable, Sendable, Equatable {
    public var accountID: String
    public var pageCount: Int
    /// Fingerprint by page index, as a string key so the JSON is a plain object.
    public var fingerprints: [String: String]

    public init(accountID: String, pageCount: Int = 0, fingerprints: [String: String] = [:]) {
        self.accountID = accountID
        self.pageCount = pageCount
        self.fingerprints = fingerprints
    }

    /// The indices whose fingerprint differs from what was last accepted.
    public func changedIndices(_ current: [String]) -> [Int] {
        current.indices.filter { fingerprints[String($0)] != current[$0] }
    }

    /// Whether anything at all needs sending: a changed page, or a different
    /// page count (a deleted page is a shorter list with nothing new in it).
    public func needsPush(_ current: [String]) -> Bool {
        pageCount != current.count || !changedIndices(current).isEmpty
    }

    /// This ledger after a push of `current` was accepted.
    public func accepting(_ current: [String]) -> PageSyncLedger {
        var next = PageSyncLedger(accountID: accountID, pageCount: current.count)
        for (index, fingerprint) in current.enumerated() {
            next.fingerprints[String(index)] = fingerprint
        }
        return next
    }

    // MARK: - Storage

    static func url(for notebook: UUID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PageSync", isDirectory: true)
            .appendingPathComponent("\(notebook.uuidString).json")
    }

    /// The ledger for `notebook` under `accountID` — empty when there is none
    /// or it belongs to another account.
    public static func load(notebook: UUID, accountID: String) -> PageSyncLedger {
        guard let data = try? Data(contentsOf: url(for: notebook)),
              let ledger = try? JSONDecoder().decode(PageSyncLedger.self, from: data),
              ledger.accountID == accountID
        else { return PageSyncLedger(accountID: accountID) }
        return ledger
    }

    public func save(notebook: UUID) {
        let url = Self.url(for: notebook)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension DocumentStore {
    /// Identifies the ink a page holds without reading it: the staged bytes'
    /// hash while a write is pending, otherwise the file's size and
    /// modification time. Two calls agree exactly when the ink is the same file.
    public func inkFingerprint(notebook: UUID, page: UUID) -> String {
        if let staged = journal.pending(page: page) {
            var hasher = Hasher()
            staged.withUnsafeBytes { hasher.combine(bytes: $0) }
            return "s\(staged.count):\(hasher.finalize())"
        }
        return Self.fileVersion(of: pageURL(notebook: notebook, page: page)).map { "f\($0)" } ?? "none"
    }
}
