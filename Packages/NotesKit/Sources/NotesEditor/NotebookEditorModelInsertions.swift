import ClassMateTheme
import CoreGraphics
import Foundation
import NotesModels
import NotesServices
import UIKit

/// Everything that gets *placed* on a page: photos, files, links, voice notes,
/// text boxes, imported pages, and strips of sticky tape. Each insertion is sized
/// and centred in the page's own logical space, so an A5 page never gets an
/// A4-sized bubble.
extension NotebookEditorModel {

    func center(width: Double, height: Double, on pageID: UUID?) -> (Double, Double) {
        let size = page(pageID)?.logicalSize ?? PageGeometry.size
        let x = (size.width - width) / 2
        let y = (size.height - height) / 2
        return (max(0, x), max(0, y))
    }

    public func insertImage(_ data: Data, fileExtension: String) async {
        guard let pageID = existingTargetPageID,
              let filename = try? await store.saveMedia(data, notebook: notebookID, fileExtension: fileExtension) else { return }
        let pageSize = page(pageID)?.logicalSize ?? PageGeometry.size
        let size = Self.fittedImageSize(data, in: pageSize)
        let (x, y) = center(width: size.width, height: size.height, on: pageID)
        await append(PageElement(
            kind: .image, x: x, y: y, width: size.width, height: size.height,
            payloadFilename: filename
        ), to: pageID)
    }

    /// Imports a PDF: appends one annotatable page per PDF page (each with the
    /// rendered page as its background). Returns the first imported page id.
    @discardableResult
    public func importPDF(_ data: Data) async -> UUID? {
        let insertAt = focusedPageID.flatMap { id in
            manifest?.pages.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        }
        guard let result = try? await store.importPDF(data: data, notebook: notebookID, at: insertAt) else {
            return nil
        }
        manifest = result.manifest
        if let id = result.firstPageID { focusedPageID = id }
        return result.firstPageID
    }

    /// Imports photos / scanned pages as annotatable page backgrounds.
    @discardableResult
    public func importImages(_ images: [Data]) async -> UUID? {
        let insertAt = focusedPageID.flatMap { id in
            manifest?.pages.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        }
        guard let result = try? await store.importImages(
            images, notebook: notebookID, at: insertAt
        ) else { return nil }
        manifest = result.manifest
        if let id = result.firstPageID { focusedPageID = id }
        return result.firstPageID
    }

    public func insertFile(_ data: Data, displayName: String, fileExtension: String) async {
        guard let pageID = existingTargetPageID,
              let filename = try? await store.saveMedia(data, notebook: notebookID, fileExtension: fileExtension) else { return }
        let (x, y) = center(width: 260, height: 68, on: pageID)
        await append(PageElement(
            kind: .file, x: x, y: y, width: 260, height: 68,
            payloadFilename: filename, displayName: displayName
        ), to: pageID)
    }

    /// Drops a tappable link chip on the page.
    public func insertLink(_ url: URL, displayName: String? = nil) async {
        guard let pageID = existingTargetPageID else { return }
        let (x, y) = center(width: 280, height: 60, on: pageID)
        await append(PageElement(
            kind: .link, x: x, y: y, width: 280, height: 60,
            displayName: displayName ?? url.host() ?? url.absoluteString,
            urlString: url.absoluteString
        ), to: pageID)
    }

    public func insertVoice(fileURL: URL, duration: TimeInterval) async {
        guard let pageID = existingTargetPageID,
              let data = try? Data(contentsOf: fileURL),
              let filename = try? await store.saveMedia(data, notebook: notebookID, fileExtension: "m4a") else { return }
        let (x, y) = center(width: 240, height: 52, on: pageID)
        await append(PageElement(
            kind: .audio, x: x, y: y, width: 240, height: 52,
            payloadFilename: filename, durationSeconds: duration
        ), to: pageID)
    }

    public func insertText(_ text: String, fontName: String, colorHex: String) async {
        guard let pageID = targetPageID, !text.isEmpty else { return }
        let pageSize = page(pageID)?.logicalSize ?? PageGeometry.size
        let width = min(460.0, pageSize.width - 48)
        let height = min(pageSize.height * 0.6, max(80, Double(text.count) / 40 * 26 + 60))
        let (x, y) = center(width: width, height: height, on: pageID)
        await append(PageElement(
            kind: .text, x: x, y: y, width: width, height: height,
            text: text, fontName: fontName, textColorHex: colorHex
        ), to: pageID)
    }

    /// Drops an empty text box where the user tapped and returns its id, so the
    /// editor can put the keyboard straight into it.
    @discardableResult
    public func insertTextBox(
        at point: CGPoint, on pageID: UUID, fontName: String, fontSize: Double, colorHex: String?
    ) async -> UUID? {
        let pageSize = page(pageID)?.logicalSize ?? PageGeometry.size
        let width = min(320.0, pageSize.width - 32)
        let height = max(fontSize * 2, 52)
        let element = PageElement(
            kind: .text,
            x: min(max(point.x - width / 2, 12), max(12, pageSize.width - width - 12)),
            y: min(max(point.y - height / 2, 12), max(12, pageSize.height - height - 12)),
            width: width, height: height,
            text: "", fontName: fontName, textColorHex: colorHex, fontSize: fontSize
        )
        await append(element, to: pageID)
        return element.id
    }

    /// Drops an empty code block where the user tapped and returns its id, so
    /// the editor can put the keyboard straight into it — same shape as
    /// `insertTextBox`, styled instead from the code-block settings.
    @discardableResult
    public func insertCodeBlock(
        at point: CGPoint, on pageID: UUID, fontName: String, fontSize: Double,
        textColorHex: String?, backgroundColorHex: String?, cornerRadius: Double
    ) async -> UUID? {
        let pageSize = page(pageID)?.logicalSize ?? PageGeometry.size
        let width = min(360.0, pageSize.width - 32)
        let height = max(fontSize * 4, 100)
        let element = PageElement(
            kind: .codeBlock,
            x: min(max(point.x - width / 2, 12), max(12, pageSize.width - width - 12)),
            y: min(max(point.y - height / 2, 12), max(12, pageSize.height - height - 12)),
            width: width, height: height,
            text: "", fontName: fontName, textColorHex: textColorHex,
            codeCornerRadius: cornerRadius, fontSize: fontSize,
            colorHex: backgroundColorHex
        )
        await append(element, to: pageID)
        return element.id
    }

    // MARK: - Tape

    /// Lays a strip of tape over the page. `points` are in the page's logical
    /// space; for a rectangle they're the two drag corners.
    @discardableResult
    public func insertTape(
        points: [CGPoint], on pageID: UUID, shape: TapeShape, pattern: TapePattern,
        colorHex: String, thickness: Double
    ) async -> UUID? {
        guard points.count >= 2 else { return nil }
        let pageSize = page(pageID)?.logicalSize ?? PageGeometry.size
        let frame: CGRect
        if shape == .rectangle {
            let rect = CGRect(
                x: min(points[0].x, points[points.count - 1].x),
                y: min(points[0].y, points[points.count - 1].y),
                width: abs(points[points.count - 1].x - points[0].x),
                height: abs(points[points.count - 1].y - points[0].y)
            )
            frame = rect.intersection(CGRect(origin: .zero, size: pageSize))
        } else {
            frame = TapeGeometry.frame(for: points, thickness: thickness, in: pageSize)
        }
        guard frame.width > 4, frame.height > 4 else { return nil }
        // Paths are stored relative to the element, so moving a strip moves its ink.
        let relative = TapeGeometry.path(for: shape, from: points).map {
            PagePoint(x: $0.x - frame.minX, y: $0.y - frame.minY)
        }
        let element = PageElement(
            kind: .tape,
            x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
            tapeShape: shape, tapePattern: pattern, colorHex: colorHex,
            points: relative, strokeWidth: thickness
        )
        await append(element, to: pageID)
        return element.id
    }

    /// Tap a strip: lift it to reveal what's under it, or put it back.
    public func toggleTape(_ elementID: UUID, on pageID: UUID) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID }),
              let index = current.pages[pageIndex].elements.firstIndex(where: { $0.id == elementID })
        else { return }
        current.pages[pageIndex].elements[index].isHidden.toggle()
        manifest = current
        _ = try? await store.setElements(
            current.pages[pageIndex].elements, notebook: notebookID, page: pageID
        )
    }

    /// "All Hidden" / "All Display" — lifts or replaces every strip on the page.
    public func setAllTape(hidden: Bool, on pageID: UUID?) async {
        guard var current = manifest else { return }
        let targets = pageID.map { [$0] } ?? current.pages.map(\.id)
        for target in targets {
            guard let pageIndex = current.pages.firstIndex(where: { $0.id == target }) else { continue }
            for index in current.pages[pageIndex].elements.indices
            where current.pages[pageIndex].elements[index].kind == .tape {
                current.pages[pageIndex].elements[index].isHidden = hidden
            }
            _ = try? await store.setElements(
                current.pages[pageIndex].elements, notebook: notebookID, page: target
            )
        }
        manifest = current
    }

}
