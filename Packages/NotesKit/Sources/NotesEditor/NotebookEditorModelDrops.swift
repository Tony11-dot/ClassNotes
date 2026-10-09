import CoreGraphics
import Foundation
import NotesModels

/// Things dragged onto a page land WHERE they were dropped, on the page they
/// were dropped on. The insertions behind the toolbar centre on the focused
/// page, which is right for a button and wrong for a drop: the user has just
/// said exactly where they want it.
extension NotebookEditorModel {

    /// Places `item` on `pageID`, centred on `point` (page-logical points) and
    /// kept on the page. A PDF becomes pages after `pageID` instead. Returns
    /// the import outcome for a PDF (nil when it couldn't be read), and a
    /// placeholder outcome for everything else that landed; nil means nothing
    /// was placed.
    @discardableResult
    public func drop(
        _ item: DroppedItem, on pageID: UUID, at point: CGPoint,
        fontName: String, colorHex: String
    ) async -> ImportOutcome? {
        guard let page = page(pageID) else { return nil }
        let pageSize = page.logicalSize
        switch item {
        case .pdf(let data, _):
            // Pages go after the page it was dropped on, not after whichever
            // page happened to have the focus.
            focusedPageID = pageID
            return await importPDF(data)
        case .image(let data, _, let ext):
            let frame = DropRouting.frame(
                size: Self.fittedImageSize(data, in: pageSize), centredAt: point, on: pageSize
            )
            guard let filename = await storeMedia(data, notebook: notebookID, fileExtension: ext) else { return nil }
            await append(PageElement(
                kind: .image, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                payloadFilename: filename
            ), to: pageID)
        case .link(let url):
            let frame = DropRouting.frame(size: CGSize(width: 280, height: 60), centredAt: point, on: pageSize)
            await append(PageElement(
                kind: .link, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                displayName: url.host() ?? url.absoluteString, urlString: url.absoluteString
            ), to: pageID)
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let width = min(460.0, pageSize.width - 48)
            let height = min(pageSize.height * 0.6, max(80, Double(trimmed.count) / 40 * 26 + 60))
            let frame = DropRouting.frame(size: CGSize(width: width, height: height), centredAt: point, on: pageSize)
            await append(PageElement(
                kind: .text, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                text: trimmed, fontName: fontName, textColorHex: colorHex
            ), to: pageID)
        case .file(let data, let name, let ext):
            let frame = DropRouting.frame(size: CGSize(width: 260, height: 68), centredAt: point, on: pageSize)
            guard let filename = await storeMedia(data, notebook: notebookID, fileExtension: ext) else { return nil }
            await append(PageElement(
                kind: .file, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                payloadFilename: filename, displayName: name
            ), to: pageID)
        }
        focusedPageID = pageID
        return ImportOutcome(firstPageID: pageID, skipped: 0)
    }
}
