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

    /// Imports a PDF: every page is rendered to a PNG stored in `media/` and
    /// appended as a page whose background is that image, so the student can draw
    /// on it with the full tool set. Returns the updated manifest and the id of
    /// the first imported page (to scroll to). Inserts at `index` (default: end).
    @discardableResult
    public func importPDF(
        data: Data, notebook: UUID, at index: Int? = nil, style: PageStyle? = nil
    ) throws -> (manifest: NotebookManifest, firstPageID: UUID?) {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            throw ImportError.unreadablePDF
        }
        var current = try manifest(for: notebook)
        // Imported pages inherit the notebook's geometry so the scroll stays even.
        let pageStyle = style ?? PageStyle.imported(
            size: current.pages.first?.pageSize ?? .classic,
            orientation: current.pages.first?.orientation ?? .portrait
        )
        var newPages: [PageRecord] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i),
                  let png = Self.renderPDFPage(page, fitting: pageStyle.logicalSize) else { continue }
            let filename = try saveMedia(png, notebook: notebook, fileExtension: "png")
            newPages.append(pageStyle.makePage(backgroundPayloadFilename: filename))
        }
        guard !newPages.isEmpty else { throw ImportError.unreadablePDF }
        let insertAt = max(0, min(index ?? current.pages.count, current.pages.count))
        current.pages.insert(contentsOf: newPages, at: insertAt)
        try writeManifest(current, for: notebook)
        return (current, newPages.first?.id)
    }

    /// Turns images (a photo pick, or the pages of a document scan) into
    /// annotatable pages: each is letterboxed onto the page background, so every
    /// drawing tool works over it. Returns the id of the first page added.
    @discardableResult
    public func importImages(
        _ images: [Data], notebook: UUID, at index: Int? = nil, style: PageStyle? = nil
    ) throws -> (manifest: NotebookManifest, firstPageID: UUID?) {
        var current = try manifest(for: notebook)
        let pageStyle = style ?? PageStyle.imported(
            size: current.pages.first?.pageSize ?? .classic,
            orientation: current.pages.first?.orientation ?? .portrait
        )
        var newPages: [PageRecord] = []
        for data in images {
            guard let png = Self.renderImage(data, fitting: pageStyle.logicalSize) else { continue }
            let filename = try saveMedia(png, notebook: notebook, fileExtension: "png")
            newPages.append(pageStyle.makePage(backgroundPayloadFilename: filename))
        }
        guard !newPages.isEmpty else { throw ImportError.unreadableImage }
        let insertAt = max(0, min(index ?? current.pages.count, current.pages.count))
        current.pages.insert(contentsOf: newPages, at: insertAt)
        try writeManifest(current, for: notebook)
        return (current, newPages.first?.id)
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
