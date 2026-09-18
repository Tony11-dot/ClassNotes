import Foundation
import NotesModels
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(UIKit)
import UIKit
#endif

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
    /// Page ids explicitly deleted this session, so a save already in flight
    /// when the deletion happens can never write that ink back — see
    /// `savePageData`'s doc comment for the exact race this closes. Unlike
    /// ordinary orphan recovery (a manifest write that never landed for a page
    /// that was always meant to exist, which this must NOT block), a
    /// tombstoned id is a page that's gone for good: once here, always here,
    /// for the life of this store. In-memory only — the race it guards
    /// against can only happen with an in-flight save from THIS run, and a
    /// fresh launch starts with no pending saves to race against.
    private var deletedPageIDs: Set<UUID> = []

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            // One-time migration from the old "ClassMateNotes" container to
            // "ClassNotes" so testers on builds 1–4 keep their notebooks.
            let fm = FileManager.default
            let newContainer = support.appendingPathComponent("ClassNotes", isDirectory: true)
            let oldContainer = support.appendingPathComponent("ClassMateNotes", isDirectory: true)
            if !fm.fileExists(atPath: newContainer.path), fm.fileExists(atPath: oldContainer.path) {
                try? fm.moveItem(at: oldContainer, to: newContainer)
            }
            self.rootURL = newContainer.appendingPathComponent("Notebooks", isDirectory: true)
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
    public func createDocument(
        id: UUID,
        firstPageTemplate: PageTemplate,
        margin: PageMargin = .default,
        paperColorHex: String? = nil
    ) throws -> NotebookManifest {
        try createDocument(
            id: id,
            style: PageStyle(
                template: firstPageTemplate, margin: margin, paperColorHex: paperColorHex
            )
        )
    }

    /// Creates a package with `pageCount` identical pages in `style`, optionally
    /// preceded by the cover as page one. A quick note asks for two pages;
    /// everything else starts at one.
    @discardableResult
    public func createDocument(
        id: UUID,
        style: PageStyle,
        pageCount: Int = 1,
        includesCover: Bool = false
    ) throws -> NotebookManifest {
        try FileManager.default.createDirectory(
            at: pagesDirectory(for: id),
            withIntermediateDirectories: true
        )
        var pages = (0..<max(1, pageCount)).map { _ in style.makePage() }
        if includesCover { pages.insert(style.makeCoverPage(), at: 0) }
        let manifest = NotebookManifest(pages: pages)
        try writeManifest(manifest, for: id)
        return manifest
    }

    /// Gives a notebook written before v7 its cover page, exactly once: the cover
    /// goes in front of page one and the manifest is stamped current, so a cover
    /// the user later deletes stays deleted instead of growing back on every open.
    ///
    /// The guard is `coverPageVersion`, NOT `currentVersion`: those were the same
    /// number only while v7 was newest, and keying off the latter would hand a
    /// cover back to every v7 notebook the first time any later field was added.
    ///
    /// Returns the manifest either way, so the caller can just use the result.
    @discardableResult
    public func ensureCoverPage(notebook id: UUID, style: PageStyle) throws -> NotebookManifest {
        var current = try manifest(for: id)
        guard current.version < NotebookManifest.coverPageVersion else {
            // Already past the cover migration, but possibly stamped older than
            // today's format — bring the stamp forward so it's read as current.
            guard current.version < NotebookManifest.currentVersion else { return current }
            current.version = NotebookManifest.currentVersion
            try writeManifest(current, for: id)
            return current
        }
        if !current.hasCoverPage {
            current.pages.insert(style.makeCoverPage(), at: 0)
        }
        current.version = NotebookManifest.currentVersion
        try writeManifest(current, for: id)
        return current
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
        // A manifest rebuilt from the blobs on disk can't know whether the
        // notebook had a cover page, so it's stamped pre-v7 and `ensureCoverPage`
        // decides — better than silently claiming "this notebook has no cover".
        var recovered = manifest ?? NotebookManifest(version: 6, pages: [])
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
        try addPage(to: id, style: PageStyle(template: template))
    }

    @discardableResult
    public func addPage(to id: UUID, style: PageStyle) throws -> NotebookManifest {
        var current = try manifest(for: id)
        current.pages.append(style.makePage())
        try writeManifest(current, for: id)
        return current
    }

    /// Atomic manifest write — `internal` so the import extension can use it.
    func writeManifest(_ manifest: NotebookManifest, for id: UUID) throws {
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

    /// A no-op once `page` has been explicitly deleted — checked against
    /// `deletedPageIDs`, not against manifest membership: a page can
    /// legitimately have ink on disk before its manifest entry exists (a crash
    /// between the two, which `orphanPageIDs` exists to recover from), and
    /// rejecting THAT write would silently lose ink the durability contract at
    /// the top of this file promises never to lose.
    ///
    /// A canvas's own coordinator has no way to know its page was deleted out
    /// from under it: SwiftUI tears down a `PKCanvasView` the instant its page
    /// leaves `model.pages`, and that teardown (`dismantleUIView`) always
    /// flushes whatever save was still pending — that's the ONE guarantee
    /// nothing gets lost when a page scrolls out of the lazy stack. But
    /// "always flush on teardown" and "a page just got deleted" are the same
    /// event from the canvas's side, and flushing then simply rewrites the
    /// `.drawing` blob `deletePage` just removed. The next manifest read
    /// (`orphanPageIDs`) finds that file back on disk with no manifest entry
    /// for it and — because that recovery exists to survive a genuinely
    /// corrupt manifest — re-adopts it as a brand new BLANK page. That is
    /// "delete ironically produces more pages" and "delete changes the page's
    /// layout" from the same cause: a delete that looked like it worked, then
    /// a stale save resurrecting the file, then self-healing mistaking the
    /// resurrection for a page that always belonged.
    public func savePageData(_ data: Data, notebook: UUID, page: UUID) throws {
        guard !deletedPageIDs.contains(page) else { return }
        try FileManager.default.createDirectory(
            at: pagesDirectory(for: notebook),
            withIntermediateDirectories: true
        )
        try data.write(to: pageURL(notebook: notebook, page: page), options: .atomic)
    }

    // MARK: - Cover render

    /// The rendered cover — artwork plus whatever was drawn on the cover page —
    /// kept as a PNG beside the pages so every list, grid and viewer can show the
    /// real cover without loading PencilKit, and the sync layer can push it.
    public nonisolated func coverImageURL(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("cover.png")
    }

    public func saveCoverImage(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(
            at: documentURL(for: id), withIntermediateDirectories: true
        )
        try data.write(to: coverImageURL(for: id), options: .atomic)
    }

    public func coverImageData(for id: UUID) -> Data? {
        try? Data(contentsOf: coverImageURL(for: id))
    }

    // MARK: - Search index

    /// The searchable text for this notebook's pages, cached beside the ink.
    ///
    /// Derived data: a missing or unreadable index is an EMPTY index, never an
    /// error and never a repair. The worst a lost `search.json` can do is make a
    /// notebook match on its title until it's read again.
    public nonisolated func searchIndexURL(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("search.json")
    }

    public func searchIndex(for id: UUID) -> SearchIndex {
        guard let data = try? Data(contentsOf: searchIndexURL(for: id)),
              let index = try? decoder.decode(SearchIndex.self, from: data)
        else { return SearchIndex() }
        return index
    }

    public func saveSearchIndex(_ index: SearchIndex, for id: UUID) throws {
        try FileManager.default.createDirectory(
            at: documentURL(for: id), withIntermediateDirectories: true
        )
        let data = try encoder.encode(index)
        try data.write(to: searchIndexURL(for: id), options: .atomic)
    }

    /// When a page's ink was last written, so the indexer can skip pages that
    /// haven't changed since it last read them.
    public func pageModifiedAt(notebook: UUID, page: UUID) -> Date? {
        try? pageURL(notebook: notebook, page: page)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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

    // MARK: - Page management (template / margin / order)

    /// Updates a page's paper template, margin, colors, rule spacing and geometry.
    /// Passing `clearPaperColor` / `clearLineColor` resets that color back to auto.
    @discardableResult
    public func updatePage(
        notebook: UUID, page: UUID, template: PageTemplate? = nil, margin: PageMargin? = nil,
        paperColorHex: String? = nil, clearPaperColor: Bool = false,
        lineColorHex: String? = nil, clearLineColor: Bool = false,
        lineSpacingSteps: Int? = nil,
        pageSize: PageSize? = nil, orientation: PageOrientation? = nil
    ) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        guard let index = current.pages.firstIndex(where: { $0.id == page }) else { return current }
        if let template { current.pages[index].template = template }
        if let margin { current.pages[index].margin = margin }
        if clearPaperColor {
            current.pages[index].paperColorHex = nil
        } else if let paperColorHex {
            current.pages[index].paperColorHex = paperColorHex
        }
        if clearLineColor {
            current.pages[index].lineColorHex = nil
        } else if let lineColorHex {
            current.pages[index].lineColorHex = lineColorHex
        }
        if let lineSpacingSteps {
            current.pages[index].lineSpacingSteps = min(
                max(lineSpacingSteps, PageLineSpacing.range.lowerBound),
                PageLineSpacing.range.upperBound
            )
        }
        if let pageSize { current.pages[index].pageSize = pageSize }
        if let orientation { current.pages[index].orientation = orientation }
        try writeManifest(current, for: notebook)
        return current
    }

    /// Flags (or unflags) a page so it can be jumped straight back to.
    ///
    /// Clearing the flag also clears the name: an unbookmarked page with a
    /// leftover title would put the old name back the next time it was flagged.
    @discardableResult
    public func setBookmark(
        notebook: UUID, page: UUID, isBookmarked: Bool, name: String? = nil
    ) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        guard let index = current.pages.firstIndex(where: { $0.id == page }) else { return current }
        current.pages[index].isBookmarked = isBookmarked
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        current.pages[index].bookmarkName = isBookmarked
            ? (trimmed?.isEmpty == false ? trimmed : current.pages[index].bookmarkName)
            : nil
        try writeManifest(current, for: notebook)
        return current
    }

    /// Copies one page's whole style onto every page in the notebook. Page *size*
    /// is deliberately included: a notebook whose pages disagreed on geometry
    /// would scroll unevenly.
    @discardableResult
    public func applyStyle(
        of page: UUID, toAllPagesOf notebook: UUID
    ) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        guard let source = current.pages.first(where: { $0.id == page })?.style else { return current }
        for index in current.pages.indices {
            current.pages[index].template = source.template
            current.pages[index].margin = source.margin
            current.pages[index].paperColorHex = source.paperColorHex
            current.pages[index].lineColorHex = source.lineColorHex
            current.pages[index].lineSpacingSteps = source.lineSpacingSteps
            current.pages[index].pageSize = source.pageSize
            current.pages[index].orientation = source.orientation
        }
        try writeManifest(current, for: notebook)
        return current
    }

    /// Inserts a new blank page at `index` (clamped), inheriting the given
    /// template + margin. Returns the manifest and the new page.
    public func insertPage(
        notebook: UUID, at index: Int, template: PageTemplate, margin: PageMargin
    ) throws -> (manifest: NotebookManifest, page: PageRecord) {
        try insertPage(
            notebook: notebook, at: index,
            style: PageStyle(template: template, margin: margin)
        )
    }

    public func insertPage(
        notebook: UUID, at index: Int, style: PageStyle
    ) throws -> (manifest: NotebookManifest, page: PageRecord) {
        var current = try manifest(for: notebook)
        let page = style.makePage()
        let clamped = max(0, min(index, current.pages.count))
        current.pages.insert(page, at: clamped)
        try writeManifest(current, for: notebook)
        return (current, page)
    }

    /// Every media file a page actually uses: its own background (an imported
    /// PDF/scan page), plus each element's payload (image/file/audio).
    private func mediaFilenames(of page: PageRecord) -> Set<String> {
        var names = Set<String>()
        if let background = page.backgroundPayloadFilename { names.insert(background) }
        for element in page.elements {
            if let filename = element.payloadFilename { names.insert(filename) }
        }
        return names
    }

    /// Deletes a page — its manifest entry, its ink blob, AND any media it
    /// alone owned. A notebook always keeps ≥1 page — deleting the last one
    /// leaves a fresh blank page.
    ///
    /// The media sweep used to not exist at all: removing a page only ever
    /// dropped its manifest entry and its `.drawing` blob, so a deleted
    /// page's photos, scans, files and voice notes sat in `media/` forever —
    /// gone from every list, permanently unreachable, but never actually off
    /// disk. A duplicate keeps the SAME filenames as its source
    /// (`duplicatePage`), so a filename is only safe to remove once no
    /// surviving page references it — checked against `current.pages` AFTER
    /// the deletion, not before.
    @discardableResult
    public func deletePage(notebook: UUID, page: UUID) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        guard let removed = current.pages.first(where: { $0.id == page }) else { return current }
        deletedPageIDs.insert(page)
        current.pages.removeAll { $0.id == page }
        if current.pages.isEmpty {
            current.pages = [PageRecord(template: .blank)]
        }
        try? FileManager.default.removeItem(at: pageURL(notebook: notebook, page: page))
        let stillNeeded = current.pages.reduce(into: Set<String>()) { $0.formUnion(mediaFilenames(of: $1)) }
        for filename in mediaFilenames(of: removed) where !stillNeeded.contains(filename) {
            try? FileManager.default.removeItem(at: mediaURL(notebook: notebook, filename: filename))
        }
        try writeManifest(current, for: notebook)
        return current
    }

    /// Moves the page at `from` to `to` (array reorder).
    @discardableResult
    public func movePage(notebook: UUID, from: Int, to: Int) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        guard current.pages.indices.contains(from) else { return current }
        let page = current.pages.remove(at: from)
        let clamped = max(0, min(to, current.pages.count))
        current.pages.insert(page, at: clamped)
        try writeManifest(current, for: notebook)
        return current
    }

    /// Duplicates a page — copies its settings and ink blob under a new id,
    /// inserted right after the original.
    @discardableResult
    public func duplicatePage(notebook: UUID, page: UUID) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        guard let index = current.pages.firstIndex(where: { $0.id == page }) else { return current }
        let source = current.pages[index]
        var copy = source.style.makePage(
            backgroundPayloadFilename: source.backgroundPayloadFilename
        )
        copy.elements = source.elements
        current.pages.insert(copy, at: index + 1)
        // Copy the ink blob if the source has one.
        if let data = try? Data(contentsOf: pageURL(notebook: notebook, page: page)) {
            try? FileManager.default.createDirectory(
                at: pagesDirectory(for: notebook), withIntermediateDirectories: true
            )
            try? data.write(to: pageURL(notebook: notebook, page: copy.id), options: .atomic)
        }
        try writeManifest(current, for: notebook)
        return current
    }
}
