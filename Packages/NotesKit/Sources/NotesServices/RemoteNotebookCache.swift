import Foundation
import NotesModels

/// Read-only cache for notebooks that exist on the account but have no local
/// `.cmnote` ink package on this device (see `Notebook.isRemoteOnly`).
///
/// Deliberately independent of `DocumentStore`: a remote-only notebook has no
/// ink to write, so folding it into `DocumentStore`'s format would stretch
/// its tested corrupt-package recovery contract to cover data it was never
/// designed for. Everything here is disposable and re-fetchable from the
/// backend, so it lives under Caches — the OS may purge it under storage
/// pressure with nothing lost but a re-download.
public actor RemoteNotebookCache {
    /// A page's voice note, file or link — the same three kinds
    /// `NotebookPageAttachment` carries, resolved to a local cache file (or,
    /// for a link, the address itself).
    public struct Attachment: Sendable, Equatable {
        public let kind: String
        public let name: String
        public let durationSeconds: Double?
        public let fileURL: URL?
        public let linkURL: String?
    }

    public struct Page: Sendable, Equatable, Identifiable {
        public let id: Int   // pageIndex
        public let imageURL: URL
        public let attachments: [Attachment]
    }

    private let client: ClassMateAPIClient
    private let rootURL: URL

    public init(client: ClassMateAPIClient, rootURL: URL? = nil) {
        self.client = client
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.rootURL = caches
                .appendingPathComponent("ClassNotes", isDirectory: true)
                .appendingPathComponent("RemoteNotebooks", isDirectory: true)
        }
    }

    private func notebookDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Fetches a remote-only notebook's pages fresh and re-caches them.
    /// Best-effort: a failed request falls back to whatever was cached from
    /// the last successful fetch (empty on a first-ever miss) rather than
    /// throwing — there's nothing more useful to do with a page that can't
    /// be reached right now.
    public func pages(for notebookID: UUID, token: String) async -> [Page] {
        guard let fetched = try? await client.fetchNotebookPages(
            id: notebookID.uuidString, token: token
        ) else {
            return cachedPages(for: notebookID)
        }
        let dir = notebookDirectory(notebookID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pages: [Page] = []
        for page in fetched.pages.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            guard let imageURL = write(
                dataURL: page.dataUrl, to: dir.appendingPathComponent("page-\(page.pageIndex).png")
            ) else { continue }
            let attachments = page.attachments.enumerated().compactMap { index, attachment -> Attachment? in
                var fileURL: URL?
                if let dataUrl = attachment.dataUrl {
                    let ext = Self.fileExtension(name: attachment.name, kind: attachment.kind)
                    fileURL = write(
                        dataURL: dataUrl,
                        to: dir.appendingPathComponent("page-\(page.pageIndex)-attachment-\(index).\(ext)")
                    )
                }
                return Attachment(
                    kind: attachment.kind, name: attachment.name,
                    durationSeconds: attachment.durationSeconds,
                    fileURL: fileURL, linkURL: attachment.url
                )
            }
            pages.append(Page(id: page.pageIndex, imageURL: imageURL, attachments: attachments))
        }
        return pages
    }

    /// Whatever was cached from the last successful fetch, in the absence of
    /// a network reply. Attachments aren't reconstructed here — only the page
    /// images survive between launches, since attachment metadata (name,
    /// kind) lives in the manifest response, not in a filename.
    private func cachedPages(for notebookID: UUID) -> [Page] {
        let dir = notebookDirectory(notebookID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        let indexed: [(Int, URL)] = files.compactMap { url in
            guard url.pathExtension == "png" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("page-"), let index = Int(stem.dropFirst("page-".count)) else { return nil }
            return (index, url)
        }
        return indexed.sorted { $0.0 < $1.0 }.map { Page(id: $0.0, imageURL: $0.1, attachments: []) }
    }

    /// Caches the cover image already in hand from `RemoteLibrary.Entry` —
    /// no extra request needed, the list payload carries it.
    @discardableResult
    public func cacheCover(_ dataURL: String?, for notebookID: UUID) -> URL? {
        guard let dataURL else { return nil }
        let dir = notebookDirectory(notebookID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return write(dataURL: dataURL, to: dir.appendingPathComponent("cover.png"))
    }

    public func coverURL(for notebookID: UUID) -> URL? {
        let url = notebookDirectory(notebookID).appendingPathComponent("cover.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Decodes a `data:mime;base64,...` string to a cache file, atomically.
    private func write(dataURL: String, to url: URL) -> URL? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func fileExtension(name: String, kind: String) -> String {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty { return ext }
        return kind == "audio" ? "m4a" : "bin"
    }
}
