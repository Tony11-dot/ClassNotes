import Foundation
import NotesModels

/// Moving and copying pages between notebooks.
extension DocumentStore {

    /// What a transfer did.
    public struct TransferResult: Sendable {
        /// The destination's pages after the transfer.
        public var target: NotebookManifest
        /// The source's pages after the transfer (unchanged by a copy).
        public var source: NotebookManifest
        /// The new pages in the destination, in the order they were added.
        public var added: [UUID]
    }

    /// Puts copies of `pages` at the end of `target`, ink, elements, page
    /// settings and media included; with `removingFromSource`, the originals
    /// then go to the source's Recently Deleted.
    ///
    /// The order is what makes a crash cost nothing: the destination is
    /// written COMPLETELY first (blobs, media, then its manifest), and only
    /// then are the originals soft-deleted. A crash in between leaves the pages
    /// in both notebooks, never in neither — and a move's originals stay
    /// restorable from the source's Recently Deleted for the usual 30 days.
    ///
    /// Copies get new page ids: an id is a page's identity in its notebook's
    /// search index, bookmarks and trash, and the destination may already hold
    /// an earlier copy of the same page. The cover is never transferred — its
    /// paper is the source notebook's own artwork, which means nothing in
    /// another notebook — and pages keep the source's order whatever order
    /// they were picked in.
    @discardableResult
    public func transferPages(
        _ pages: [UUID], from source: UUID, to target: UUID, removingFromSource: Bool
    ) throws -> TransferResult {
        guard source != target else {
            let manifest = try manifest(for: source)
            return TransferResult(target: manifest, source: manifest, added: [])
        }
        let sourceManifest = try manifest(for: source)
        let picked = Set(pages)
        let records = sourceManifest.pages.filter { picked.contains($0.id) && !$0.isCover }
        var destination = try manifest(for: target)
        guard !records.isEmpty else {
            return TransferResult(target: destination, source: sourceManifest, added: [])
        }

        let fm = FileManager.default
        try fm.createDirectory(at: pagesDirectory(for: target), withIntermediateDirectories: true)
        var copies: [PageRecord] = []
        var written: [URL] = []
        do {
            for record in records {
                var copy = record
                copy.id = UUID()
                // Ink as the user last saw it: staged bytes first, then the file.
                if let ink = pageData(notebook: source, page: record.id) {
                    let url = pageURL(notebook: target, page: copy.id)
                    try ink.write(to: url, options: .atomic)
                    written.append(url)
                }
                for filename in mediaFilenames(of: record) {
                    let from = mediaURL(notebook: source, filename: filename)
                    let to = mediaURL(notebook: target, filename: filename)
                    // Media names are unique and never rewritten, so a file
                    // already there under the same name IS this file.
                    guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
                    try fm.createDirectory(at: mediaDirectory(for: target), withIntermediateDirectories: true)
                    try fm.copyItem(at: from, to: to)
                    written.append(to)
                }
                copies.append(copy)
            }
            destination.pages.append(contentsOf: copies)
            try writeManifest(destination, for: target)
        } catch {
            // Nothing half-copied stays behind as an orphan the next load
            // would adopt as a blank page.
            for url in written { try? fm.removeItem(at: url) }
            throw error
        }

        var after = sourceManifest
        if removingFromSource {
            for record in records {
                after = try deletePage(notebook: source, page: record.id)
            }
        }
        return TransferResult(target: destination, source: after, added: copies.map(\.id))
    }
}
