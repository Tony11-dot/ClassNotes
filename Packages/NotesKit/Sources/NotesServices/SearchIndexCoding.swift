import Foundation
import NotesModels

/// How `search.json` is written — deliberately NOT how the manifest is written.
///
/// `DocumentStore`'s shared encoder uses `.iso8601`, which has no fractional
/// seconds, so a date round-trips rounded DOWN by up to a whole second. For a
/// manifest's `createdAt` that is harmless. For `SearchIndex.indexedAt` it is
/// not: `SearchIndex.needsReindex` asks whether a page changed after it was
/// last read, and a reading stamped up to a second earlier than it really
/// happened reads as stale against ink saved in that same second — so the page
/// is handed to Vision again, every launch, forever.
///
/// Adding fractional seconds is not enough either: an ISO-8601 string carries
/// milliseconds and a `Date` is finer than that, so the value that comes back
/// is still not the value that went in. The index is derived data, rebuilt
/// whenever it cannot be read, so it stores the raw interval and gets the
/// number back unchanged — which costs nothing and changes no document on disk.
enum SearchIndexCoding {
    /// `.deferredToDate` is the raw `timeIntervalSinceReferenceDate`, which
    /// JSON round-trips exactly.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let decoder = JSONDecoder()
        // Indexes already on disk were written by the shared `.iso8601` encoder
        // and must still decode, or every notebook silently loses its index and
        // re-reads itself once — the exact cost this is here to avoid.
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            if let interval = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            let raw = try container.decode(String.self)
            if let date = isoFractional.date(from: raw) { return date }
            if let date = iso.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unreadable date \(raw)"
            )
        }
        return decoder
    }()
}
