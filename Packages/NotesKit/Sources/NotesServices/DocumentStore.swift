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
        try FileManager.default.createDirectory(
            at: pagesDirectory(for: id),
            withIntermediateDirectories: true
        )
        let manifest = NotebookManifest(pages: [
            PageRecord(template: firstPageTemplate, margin: margin, paperColorHex: paperColorHex)
        ])
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

    // MARK: - PDF import (each page becomes an annotatable page background)

    #if canImport(PDFKit) && canImport(UIKit)
    public enum ImportError: Error, Sendable { case unreadablePDF }

    /// Imports a PDF: every page is rendered to a PNG stored in `media/` and
    /// appended as a page whose background is that image, so the student can draw
    /// on it with the full tool set. Returns the updated manifest and the id of
    /// the first imported page (to scroll to). Inserts at `index` (default: end).
    @discardableResult
    public func importPDF(
        data: Data, notebook: UUID, at index: Int? = nil
    ) throws -> (manifest: NotebookManifest, firstPageID: UUID?) {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            throw ImportError.unreadablePDF
        }
        var current = try manifest(for: notebook)
        var newPages: [PageRecord] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i),
                  let png = Self.renderPDFPage(page, fitting: PageGeometry.size) else { continue }
            let filename = try saveMedia(png, notebook: notebook, fileExtension: "png")
            newPages.append(PageRecord(
                template: .blank,
                margin: PageMargin(position: .none),
                backgroundPayloadFilename: filename
            ))
        }
        guard !newPages.isEmpty else { throw ImportError.unreadablePDF }
        let insertAt = max(0, min(index ?? current.pages.count, current.pages.count))
        current.pages.insert(contentsOf: newPages, at: insertAt)
        try writeManifest(current, for: notebook)
        return (current, newPages.first?.id)
    }

    /// Renders one PDF page into a `target`-sized PNG (white paper, aspect-fit,
    /// centered) in the fixed logical page space.
    private nonisolated static func renderPDFPage(_ page: PDFPage, fitting target: CGSize) -> Data? {
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = min(target.width / pageRect.width, target.height / pageRect.height)
        let drawn = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let origin = CGPoint(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            let cg = ctx.cgContext
            cg.saveGState()
            // Flip into PDF (bottom-left origin) space, then place + scale.
            cg.translateBy(x: origin.x, y: origin.y + drawn.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -pageRect.minX, y: -pageRect.minY)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
        return image.pngData()
    }
    #endif

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

    /// Updates a page's paper template, margin, and/or page color. Passing
    /// `clearPaperColor: true` resets the page color back to auto (theme paper).
    @discardableResult
    public func updatePage(
        notebook: UUID, page: UUID, template: PageTemplate? = nil, margin: PageMargin? = nil,
        paperColorHex: String? = nil, clearPaperColor: Bool = false
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
        try writeManifest(current, for: notebook)
        return current
    }

    /// Inserts a new blank page at `index` (clamped), inheriting the given
    /// template + margin. Returns the manifest and the new page.
    public func insertPage(
        notebook: UUID, at index: Int, template: PageTemplate, margin: PageMargin
    ) throws -> (manifest: NotebookManifest, page: PageRecord) {
        var current = try manifest(for: notebook)
        let page = PageRecord(template: template, margin: margin)
        let clamped = max(0, min(index, current.pages.count))
        current.pages.insert(page, at: clamped)
        try writeManifest(current, for: notebook)
        return (current, page)
    }

    /// Deletes a page (and its ink blob). A notebook always keeps ≥1 page —
    /// deleting the last one leaves a fresh blank page.
    @discardableResult
    public func deletePage(notebook: UUID, page: UUID) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        current.pages.removeAll { $0.id == page }
        if current.pages.isEmpty {
            current.pages = [PageRecord(template: .blank)]
        }
        try? FileManager.default.removeItem(at: pageURL(notebook: notebook, page: page))
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
        let copy = PageRecord(template: source.template, elements: source.elements, margin: source.margin)
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
