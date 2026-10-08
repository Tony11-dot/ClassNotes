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

    let rootURL: URL
    let encoder: JSONEncoder
    let decoder = JSONDecoder()
    /// Page ids explicitly deleted this session, so a save already in flight
    /// when the deletion happens can never write that ink back — see
    /// `savePageData`'s doc comment for the exact race this closes. Unlike
    /// ordinary orphan recovery (a manifest write that never landed for a page
    /// that was always meant to exist, which this must NOT block), a
    /// tombstoned id is a page that's gone for good: once here, always here,
    /// for the life of this store. In-memory only — the race it guards
    /// against can only happen with an in-flight save from THIS run, and a
    /// fresh launch starts with no pending saves to race against.
    var deletedPageIDs: Set<UUID> = []
    /// Orders every page write and holds ink that hasn't reached disk yet — see
    /// `PageInkJournal`. Nonisolated so a canvas can stamp and stage its
    /// snapshot synchronously, in the same turn it reads the drawing.
    public nonisolated let journal = PageInkJournal()
    /// Decoded `search.json`s, keyed by the file version they were read from.
    var searchIndexCache: [UUID: (key: String, index: NoteSearch.PreparedIndex)] = [:]

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

    func manifestURL(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("manifest.json")
    }

    /// The manifest as it was before the most recent write — see `writeManifest`.
    func manifestBackupURL(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("manifest.backup.json")
    }

    func pagesDirectory(for id: UUID) -> URL {
        documentURL(for: id).appendingPathComponent("pages", isDirectory: true)
    }

    func pageURL(notebook: UUID, page: UUID) -> URL {
        pagesDirectory(for: notebook).appendingPathComponent("\(page.uuidString).drawing")
    }

    /// Where a deleted page's ink waits in the package's trash. The orphan scan
    /// only adopts `.drawing`, so this is never mistaken for a live page.
    func trashedPageURL(notebook: UUID, page: UUID) -> URL {
        pageURL(notebook: notebook, page: page).appendingPathExtension("deleted")
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

    /// A manifest OR its backup counts: a crash between the two halves of a
    /// manifest write leaves only the backup, and that is still a document.
    public func documentExists(id: UUID) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: manifestURL(for: id).path)
            || fm.fileExists(atPath: manifestBackupURL(for: id).path)
    }

    // MARK: - Manifest

    /// Loads the manifest, self-healing from whatever survives on disk — and
    /// never at the cost of the bytes that were there.
    ///
    /// In order: the manifest itself; if it won't decode, it is moved aside
    /// (`manifest.unreadable-<time>.json`, kept for good) and the best of a
    /// SALVAGE decode of it (every page and element that still reads) and the
    /// last-known-good backup is used; only if neither reads is the page list
    /// rebuilt from the ink blobs. Rebuilding straight from the blobs and writing
    /// the result over the original was the old behaviour, and it turned one
    /// unreadable field into the loss of every image, text box, fill, bookmark,
    /// cover and page setting the notebook held.
    public func manifest(for id: UUID) throws -> NotebookManifest {
        let span = Perf.begin("Manifest load")
        defer { Perf.end("Manifest load", span) }
        let url = manifestURL(for: id)
        var manifest: NotebookManifest?
        var recoveredFromDamage = false
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? decoder.decode(NotebookManifest.self, from: data) {
                manifest = decoded
                preserveIfNewer(decoded, original: data, notebook: id)
            } else {
                quarantineManifest(notebook: id)
                manifest = bestRecovery(salvaging: data, notebook: id)
                recoveredFromDamage = true
            }
        } else if let backup = decodedBackup(notebook: id) {
            // The write was cut off between keeping the old file and landing the
            // new one: the backup IS the latest complete state.
            manifest = backup
            recoveredFromDamage = true
        }
        if recoveredFromDamage {
            Perf.event("Manifest recovered")
        }

        let trashed = Set(pageTrash(for: id).entries.map(\.id))
        let orphans = orphanPageIDs(
            for: id, knownPages: manifest?.pages ?? [], excluding: trashed
        )
        // A manifest rebuilt from the blobs on disk can't know whether the
        // notebook had a cover page, so it's stamped pre-v7 and `ensureCoverPage`
        // decides — better than silently claiming "this notebook has no cover".
        var recovered = manifest ?? NotebookManifest(version: 6, pages: [])
        if !orphans.isEmpty {
            // Adopted pages go at the END, oldest first. The pages the manifest
            // already lists keep the order the user gave them: sorting the whole
            // notebook by creation date (as this once did) undid every page
            // move the user had ever made, the first time a stray blob turned up.
            recovered.pages += orphans.sorted { $0.createdAt < $1.createdAt }.map { orphan in
                PageRecord(id: orphan.id, template: .blank, createdAt: orphan.createdAt)
            }
        }
        if recovered.pages.isEmpty {
            recovered.pages = [PageRecord(template: .blank)]
        }
        reviveLivePagesInTrash(recovered.pages.map(\.id), notebook: id)

        // Persist the healed manifest so recovery happens once, not per read.
        if manifest == nil || !orphans.isEmpty || recoveredFromDamage {
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
    ///
    /// The file being replaced is kept as `manifest.backup.json` first (a
    /// `rename`, which replaces the old backup atomically and copies nothing).
    /// What is replaced is always a manifest this store wrote or already
    /// validated — `manifest(for:)` moves an unreadable one out of the way
    /// before anything writes — so the backup is always a last-known-good copy.
    /// A crash between the rename and the write leaves the backup alone, and
    /// that is exactly the state before the interrupted write.
    func writeManifest(_ manifest: NotebookManifest, for id: UUID) throws {
        let data = try encoder.encode(manifest)
        let url = manifestURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = Darwin.rename(url.path, manifestBackupURL(for: id).path)
        }
        try data.write(to: url, options: .atomic)
    }

    private struct Orphan {
        let id: UUID
        let createdAt: Date
    }

    private func orphanPageIDs(
        for id: UUID, knownPages: [PageRecord], excluding trashed: Set<UUID> = []
    ) -> [Orphan] {
        let known = Set(knownPages.map(\.id)).union(trashed)
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
    ///
    /// Ink staged by a save that hasn't reached disk yet wins over the file: a
    /// page reopened in that gap must show what the user last saw, not the copy
    /// before it.
    public func pageData(notebook: UUID, page: UUID) -> Data? {
        if let staged = journal.pending(page: page) { return staged }
        return Perf.measure("Page read") {
            try? Data(contentsOf: pageURL(notebook: notebook, page: page))
        }
    }

    /// Moves a page blob that no longer decodes out of the way, keeping it.
    ///
    /// The canvas shows an unreadable page as blank, and the next stroke saves
    /// over the file — so without this, one corrupt write turned into the
    /// permanent loss of everything that page held. The bytes are kept beside
    /// the pages as `<id>.drawing.unreadable` (the orphan scan only adopts
    /// `.drawing`, so this never comes back as a phantom page). An existing
    /// quarantined copy is not overwritten: the first bad file is the one most
    /// likely to be recoverable.
    public func quarantinePageData(notebook: UUID, page: UUID) {
        let source = pageURL(notebook: notebook, page: page)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        // The first copy keeps the plain name; any later one gets a time stamp.
        // Nothing unreadable is ever deleted — the bytes might still be
        // recoverable by a later build, or by hand.
        var target = source.appendingPathExtension("unreadable")
        if fm.fileExists(atPath: target.path) {
            target = source.appendingPathExtension("unreadable-\(Self.fileStamp())")
        }
        try? fm.moveItem(at: source, to: target)
    }

    /// Once `page` has been explicitly deleted, the write goes to the page's
    /// place in the package trash instead of among the live pages. Checked
    /// against `deletedPageIDs`, not against manifest membership: a page can
    /// legitimately have ink on disk before its manifest entry exists (a crash
    /// between the two, which `orphanPageIDs` exists to recover from), and
    /// rejecting THAT write would silently lose ink.
    ///
    /// A canvas's coordinator has no way to know its page was deleted out from
    /// under it: SwiftUI tears down a `PKCanvasView` the instant its page leaves
    /// `model.pages`, and that teardown (`dismantleUIView`) always flushes
    /// whatever save was still pending. Written back as a live `.drawing`, the
    /// orphan scan would re-adopt it as a brand new BLANK page — "delete
    /// produces more pages". Written into the trash, it is the newest ink the
    /// page had, which is what an Undo should bring back.
    ///
    /// `stamp` orders writes (see `PageInkJournal`): a write stamped older than
    /// one already on disk is dropped, so a slow save can never put back ink a
    /// newer save had erased. Callers that read the drawing earlier must stamp
    /// it THEN; a write without one is stamped on arrival, as the newest.
    public func savePageData(
        _ data: Data, notebook: UUID, page: UUID, stamp: PageInkJournal.Stamp? = nil
    ) throws {
        let stamp = stamp ?? journal.stamp()
        guard journal.admits(stamp, page: page) else { return }
        // A deleted page's last save — the canvas flushes as it is torn down —
        // goes to the page's place in the trash, never back among the live
        // pages: an Undo then restores the page with every stroke it had.
        let target = deletedPageIDs.contains(page)
            ? trashedPageURL(notebook: notebook, page: page)
            : pageURL(notebook: notebook, page: page)
        try FileManager.default.createDirectory(
            at: pagesDirectory(for: notebook),
            withIntermediateDirectories: true
        )
        // On failure the staged copy stays readable and the next save retries;
        // the caller hears about it (the editor shows it).
        try Perf.measure("Page save") {
            try data.write(to: target, options: .atomic)
        }
        journal.settle(page: page, stamp: stamp)
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
    func mediaFilenames(of page: PageRecord) -> Set<String> {
        var names = Set<String>()
        if let background = page.backgroundPayloadFilename { names.insert(background) }
        for element in page.elements {
            if let filename = element.payloadFilename { names.insert(filename) }
        }
        return names
    }

    /// Deletes a page — into the package's TRASH, not off the disk.
    ///
    /// The record goes to `trash.json` with its position, the ink blob is
    /// renamed out of the live pages, and media is left exactly where it is:
    /// `restorePage` undoes all of it, and `purgeExpiredPages` (or emptying the
    /// trash) is the only step that removes anything. A notebook always keeps
    /// ≥1 page — deleting the last one leaves a fresh blank page.
    ///
    /// Order matters for a crash part-way through: the trash entry lands first,
    /// then the manifest without the page, then the blob is moved. Any prefix of
    /// that leaves the page either still live or recoverable from the trash —
    /// the orphan scan skips trashed ids, so a blob that hadn't moved yet is not
    /// re-adopted as a phantom blank page.
    @discardableResult
    public func deletePage(notebook: UUID, page: UUID) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        guard let index = current.pages.firstIndex(where: { $0.id == page }) else { return current }
        let removed = current.pages[index]

        var trash = pageTrash(for: notebook)
        trash.entries.removeAll { $0.id == page }
        trash.entries.append(PageTrash.Entry(page: removed, index: index, deletedAt: .now))
        try writePageTrash(trash, for: notebook)

        deletedPageIDs.insert(page)
        current.pages.remove(at: index)
        if current.pages.isEmpty {
            current.pages = [PageRecord(template: .blank)]
        }
        try writeManifest(current, for: notebook)

        // Ink not on disk yet goes with the page, so an Undo brings back every
        // stroke; otherwise the file itself is moved.
        let live = pageURL(notebook: notebook, page: page)
        let trashed = trashedPageURL(notebook: notebook, page: page)
        if let staged = journal.pending(page: page) {
            try? staged.write(to: trashed, options: .atomic)
            try? FileManager.default.removeItem(at: live)
        } else if FileManager.default.fileExists(atPath: live.path) {
            try? FileManager.default.removeItem(at: trashed)
            try? FileManager.default.moveItem(at: live, to: trashed)
        }
        journal.forget(page: page)
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
        if let data = pageData(notebook: notebook, page: page) {
            try? FileManager.default.createDirectory(
                at: pagesDirectory(for: notebook), withIntermediateDirectories: true
            )
            try? data.write(to: pageURL(notebook: notebook, page: copy.id), options: .atomic)
        }
        try writeManifest(current, for: notebook)
        return current
    }

    /// A filename-safe time stamp, unique enough for files that are never
    /// overwritten.
    nonisolated static func fileStamp(_ date: Date = .now) -> String {
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        return "\(millis)-\(UUID().uuidString.prefix(8))"
    }
}
