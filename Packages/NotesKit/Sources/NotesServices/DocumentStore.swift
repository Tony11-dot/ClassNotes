import Foundation
import NotesModels

/// Owns every notebook document package on disk.
///
/// Layout: `<root>/<uuid>.cmnote/manifest.json` + `<root>/<uuid>.cmnote/pages/<pageID>.drawing`.
///
/// Durability contract (tested):
/// - every write is atomic (temp file + rename), so a crash never leaves a
///   half-written manifest or page blob;
/// - a corrupt or missing manifest is rebuilt from the page blobs on disk —
///   ink is never lost because metadata broke;
/// - orphan page blobs (present on disk, absent from the manifest) are
///   re-adopted; manifest entries whose blob is missing stay valid empty pages.
///
/// The root lives under Application Support today; the layout is deliberately
/// a self-contained folder per notebook so it can move into an iCloud
/// container without a format change.
public actor DocumentStore {
    public static let fileExtension = "cmnote"

    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.rootURL = support
                .appendingPathComponent("ClassMateNotes", isDirectory: true)
                .appendingPathComponent("Notebooks", isDirectory: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - URLs

    public nonisolated func documentURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)", isDirectory: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("manifest.json")
    }

    private func pagesDirectory(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("pages", isDirectory: true)
    }

    private func pageURL(notebook: UUID, page: UUID) -> URL {
        pagesDirectory(for: notebook).appendingPathComponent("\(page.uuidString).drawing")
    }

    /// Where image / file / audio payloads for page elements live.
    public nonisolated func mediaDirectory(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("media", isDirectory: true)
    }

    public nonisolated func mediaURL(notebook: UUID, filename: String) -> URL {
        mediaDirectory(for: notebook).appendingPathComponent(filename)
    }

    // MARK: - Lifecycle

    @discardableResult
    public func createDocument(id: UUID, firstPageTemplate: PageTemplate) throws -> NotebookManifest {
        try FileManager.default.createDirectory(
            at: pagesDirectory(for: id),
            withIntermediateDirectories: true
        )
        let manifest = NotebookManifest(pages: [PageRecord(template: firstPageTemplate)])
        try writeManifest(manifest, for: id)
        return manifest
    }

    public func deleteDocument(id: UUID) throws {
        let url = documentURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func documentExists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(for: id).path)
    }

    // MARK: - Manifest

    /// Loads the manifest, self-healing from whatever survives on disk.
    public func manifest(for id: UUID) throws -> NotebookManifest {
        let url = manifestURL(for: id)
        var manifest: NotebookManifest?
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(NotebookManifest.self, from: data) {
            manifest = decoded
        }

        let orphans = orphanPageIDs(for: id, knownPages: manifest?.pages ?? [])
        var recovered = manifest ?? NotebookManifest(pages: [])
        if !orphans.isEmpty {
            recovered.pages += orphans.map { orphan in
                PageRecord(id: orphan.id, template: .blank, createdAt: orphan.createdAt)
            }
            recovered.pages.sort { $0.createdAt < $1.createdAt }
        }
        if recovered.pages.isEmpty {
            recovered.pages = [PageRecord(template: .blank)]
        }

        // Persist the healed manifest so recovery happens once, not per read.
        if manifest == nil || !orphans.isEmpty {
            try FileManager.default.createDirectory(
                at: pagesDirectory(for: id),
                withIntermediateDirectories: true
            )
            try writeManifest(recovered, for: id)
        }
        return recovered
    }

    @discardableResult
    public func addPage(to id: UUID, template: PageTemplate) throws -> NotebookManifest {
        var current = try manifest(for: id)
        current.pages.append(PageRecord(template: template))
        try writeManifest(current, for: id)
        return current
    }

    private func writeManifest(_ manifest: NotebookManifest, for id: UUID) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: id), options: .atomic)
    }

    private struct Orphan {
        let id: UUID
        let createdAt: Date
    }

    private func orphanPageIDs(for id: UUID, knownPages: [PageRecord]) -> [Orphan] {
        let known = Set(knownPages.map(\.id))
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: pagesDirectory(for: id),
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        return contents.compactMap { url in
            guard url.pathExtension == "drawing",
                  let pageID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !known.contains(pageID) else { return nil }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            return Orphan(id: pageID, createdAt: created)
        }
    }

    // MARK: - Page ink

    /// `nil` means the page has never been drawn on — a valid empty page.
    public func pageData(notebook: UUID, page: UUID) -> Data? {
        try? Data(contentsOf: pageURL(notebook: notebook, page: page))
    }

    public func savePageData(_ data: Data, notebook: UUID, page: UUID) throws {
        try FileManager.default.createDirectory(
            at: pagesDirectory(for: notebook),
            withIntermediateDirectories: true
        )
        try data.write(to: pageURL(notebook: notebook, page: page), options: .atomic)
    }

    // MARK: - Media payloads + page elements

    /// Stores an image/file/audio payload and returns the filename to reference
    /// it by from a `PageElement`.
    @discardableResult
    public func saveMedia(_ data: Data, notebook: UUID, fileExtension: String) throws -> String {
        try FileManager.default.createDirectory(
            at: mediaDirectory(for: notebook),
            withIntermediateDirectories: true
        )
        let filename = "\(UUID().uuidString).\(fileExtension)"
        try data.write(to: mediaURL(notebook: notebook, filename: filename), options: .atomic)
        return filename
    }

    public func mediaData(notebook: UUID, filename: String) -> Data? {
        try? Data(contentsOf: mediaURL(notebook: notebook, filename: filename))
    }

    /// Replaces the element list for one page (atomic manifest rewrite).
    @discardableResult
    public func setElements(_ elements: [PageElement], notebook: UUID, page: UUID) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        guard let index = current.pages.firstIndex(where: { $0.id == page }) else { return current }
        current.pages[index].elements = elements
        try writeManifest(current, for: notebook)
        return current
    }
}
