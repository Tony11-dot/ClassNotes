import Foundation
import NotesModels
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Turning outside material into pages you can draw on: a PDF, photos from the
/// library, or a document scan. Every imported page is rendered to a PNG in the
/// package's `media/` folder and set as a page background, so the full tool set
/// works over it — the import becomes real paper, not a read-only attachment.
extension DocumentStore {

    public enum ImportError: Error, Sendable {
        case unreadablePDF
        case unreadableImage
    }

    /// What an import added.
    public struct ImportResult: Sendable {
        public var manifest: NotebookManifest
        public var firstPageID: UUID?
        /// Pages the source had that couldn't be rendered and were left out —
        /// reported, never silently dropped.
        public var skipped: Int
    }

    /// Imports a PDF: every page is rendered to a PNG stored in `media/` and
    /// added as a page whose background is that image, so the student can draw
    /// on it with the full tool set. Inserts at `index` (default: end).
    ///
    /// Rendering runs OFF the store's actor, one page at a time inside its own
    /// autorelease pool, and the manifest is written once at the end. It used to
    /// run inside the actor with the whole document's renders alive until the
    /// loop finished: every ink save in the open notebook queued behind the
    /// import for as long as it took, and a long PDF ran the app out of memory
    /// part-way — taking the import and anything unsaved with it. A failed or
    /// cancelled import removes the media it had written, so nothing is left
    /// behind.
    @concurrent
    public nonisolated func importPDF(
        data: Data, notebook: UUID, at index: Int? = nil, style: PageStyle? = nil,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> ImportResult {
        let span = Perf.begin("PDF import")
        defer { Perf.end("PDF import", span) }
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            throw ImportError.unreadablePDF
        }
        let pageStyle = try await importStyle(style, notebook: notebook)
        let source = PageSource(count: pdf.pageCount) { number in
            autoreleasepool {
                pdf.page(at: number).flatMap { Self.renderPDFPage($0, fitting: pageStyle.logicalSize) }
            }
        }
        return try await importPages(source, notebook: notebook, at: index, style: pageStyle, progress: progress)
    }

    /// Turns images (a photo pick, or the pages of a document scan) into
    /// annotatable pages: each is letterboxed onto the page background, so every
    /// drawing tool works over it. Same off-actor, one-at-a-time rendering as
    /// `importPDF`.
    @concurrent
    public nonisolated func importImages(
        _ images: [Data], notebook: UUID, at index: Int? = nil, style: PageStyle? = nil,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> ImportResult {
        let pageStyle = try await importStyle(style, notebook: notebook)
        do {
            let source = PageSource(count: images.count) { number in
                autoreleasepool { Self.renderImage(images[number], fitting: pageStyle.logicalSize) }
            }
            return try await importPages(source, notebook: notebook, at: index, style: pageStyle, progress: progress)
        } catch ImportError.unreadablePDF {
            throw ImportError.unreadableImage
        }
    }

    /// The pages an import renders, one at a time, by number.
    private struct PageSource {
        let count: Int
        let render: (Int) -> Data?
    }

    /// The shared loop: render, write, repeat — then one manifest write.
    private nonisolated func importPages(
        _ source: PageSource, notebook: UUID, at index: Int?, style: PageStyle,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ImportResult {
        let total = source.count
        let fm = FileManager.default
        try fm.createDirectory(at: mediaDirectory(for: notebook), withIntermediateDirectories: true)
        var newPages: [PageRecord] = []
        var written: [URL] = []
        var skipped = 0
        do {
            for number in 0..<total {
                try Task.checkCancellation()
                guard let png = source.render(number) else {
                    skipped += 1
                    continue
                }
                let filename = "\(UUID().uuidString).png"
                let url = mediaURL(notebook: notebook, filename: filename)
                try png.write(to: url, options: .atomic)
                written.append(url)
                newPages.append(style.makePage(backgroundPayloadFilename: filename))
                progress?(number + 1, total)
            }
            guard !newPages.isEmpty else { throw ImportError.unreadablePDF }
            let manifest = try await insertImportedPages(newPages, notebook: notebook, at: index)
            return ImportResult(manifest: manifest, firstPageID: newPages.first?.id, skipped: skipped)
        } catch {
            for url in written { try? fm.removeItem(at: url) }
            throw error
        }
    }

    /// Imported pages inherit the notebook's geometry so the scroll stays even.
    private func importStyle(_ style: PageStyle?, notebook: UUID) throws -> PageStyle {
        if let style { return style }
        let current = try manifest(for: notebook)
        return PageStyle.imported(
            size: current.pages.first?.pageSize ?? .classic,
            orientation: current.pages.first?.orientation ?? .portrait
        )
    }

    /// Reads the manifest FRESH at the end of an import — the user may have
    /// kept writing while it ran — and adds the pages in one write.
    private func insertImportedPages(
        _ pages: [PageRecord], notebook: UUID, at index: Int?
    ) throws -> NotebookManifest {
        var current = try manifest(for: notebook)
        let insertAt = max(0, min(index ?? current.pages.count, current.pages.count))
        current.pages.insert(contentsOf: pages, at: insertAt)
        try writeManifest(current, for: notebook)
        return current
    }

    /// Draws an image aspect-fit and centered on a `target`-sized white page.
    private nonisolated static func renderImage(_ data: Data, fitting target: CGSize) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let scale = min(target.width / image.size.width, target.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: origin, size: drawn))
        }.pngData()
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

}
