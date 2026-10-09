import CoreGraphics
import Foundation
import NotesModels

/// Drawing a PDF page where `PDFPageFit` says it goes, for every place a page
/// imported from a PDF is drawn: the PNG made at import, the live tiles, the
/// export. Core Graphics only, so it is safe on the background threads a tiled
/// layer draws on.
public enum PDFPageDrawing {
    /// Draws `page` aspect-fit and centred in `target`, in a top-left-origin
    /// context.
    public static func draw(_ page: CGPDFPage, in target: CGRect, context: CGContext) {
        let box = page.getBoxRect(.mediaBox)
        context.saveGState()
        context.concatenate(PDFPageFit.transform(mediaBox: box, rotation: Int(page.rotationAngle), in: target))
        context.clip(to: box)
        context.interpolationQuality = .high
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// Open PDFs by file, so a hundred pages from one PDF share one document.
    /// `CGPDFDocument` is safe to draw from several threads at once.
    private static let cache = PDFDocumentCache()

    /// Page `index` (from 0) of the PDF at `url`.
    public static func page(at url: URL, index: Int) -> CGPDFPage? {
        cache.document(at: url)?.page(at: index + 1)
    }
}

private final class PDFDocumentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [URL: CGPDFDocument] = [:]
    private var order: [URL] = []
    private let limit = 8

    func document(at url: URL) -> CGPDFDocument? {
        lock.lock()
        defer { lock.unlock() }
        if let open = documents[url] { return open }
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        documents[url] = document
        order.append(url)
        if order.count > limit { documents[order.removeFirst()] = nil }
        return document
    }
}
