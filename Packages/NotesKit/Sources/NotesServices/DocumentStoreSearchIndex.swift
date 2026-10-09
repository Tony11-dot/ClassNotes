import Foundation
import NotesModels

/// The package's derived search data (`search.json`), and the file facts the
/// indexer decides staleness from.
extension DocumentStore {

    /// The searchable text for this notebook's pages, cached beside the ink.
    ///
    /// Derived data: a missing or unreadable index is an EMPTY index, never an
    /// error and never a repair. The worst a lost `search.json` can do is make a
    /// notebook match on its title until it's read again.
    public nonisolated func searchIndexURL(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("search.json")
    }

    public func searchIndex(for id: UUID) -> SearchIndex {
        preparedSearchIndex(for: id).index
    }

    /// The index decoded and folded once per version of the file. A library
    /// search reads EVERY notebook's index and runs again on each pause in
    /// typing; reading and decoding a thousand pages of unchanged text each
    /// time roughly doubled a search (measured: ~20–35 ms cold, ~8–15 ms warm,
    /// in the benchmarks). The file's size and modification time are the key —
    /// a stat, not a read — so an index rewritten by the indexer, or replaced
    /// by anything else, reads fresh.
    public func preparedSearchIndex(for id: UUID) -> NoteSearch.PreparedIndex {
        let url = searchIndexURL(for: id)
        guard let key = Self.fileVersion(of: url) else {
            searchIndexCache[id] = nil
            return NoteSearch.PreparedIndex(SearchIndex())
        }
        if let cached = searchIndexCache[id], cached.key == key { return cached.index }
        guard let data = try? Data(contentsOf: url),
              let index = try? SearchIndexCoding.decoder.decode(SearchIndex.self, from: data)
        else { return NoteSearch.PreparedIndex(SearchIndex()) }
        let prepared = NoteSearch.PreparedIndex(index)
        searchIndexCache[id] = (key, prepared)
        return prepared
    }

    /// A no-op for a notebook with no package: the index is derived from the
    /// package, and a derived file must never be what creates one.
    public func saveSearchIndex(_ index: SearchIndex, for id: UUID) throws {
        guard FileManager.default.fileExists(atPath: documentURL(for: id).path) else { return }
        let data = try SearchIndexCoding.encoder.encode(index)
        let url = searchIndexURL(for: id)
        try data.write(to: url, options: .atomic)
        // Folded on the next search, not here: the indexer writes indexes for
        // the whole library at launch, and most are never searched that session.
        searchIndexCache[id] = nil
    }

    /// Size and modification time: what changes whenever a file's bytes do.
    nonisolated static func fileVersion(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return "\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// When a page's ink was last written, so the indexer can skip pages that
    /// haven't changed since it last read them.
    public func pageModifiedAt(notebook: UUID, page: UUID) -> Date? {
        try? pageURL(notebook: notebook, page: page)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
