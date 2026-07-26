import ClassMateTheme
import Foundation
import NotesModels
import NotesServices
import Observation
import PencilKit
import SwiftUI
import UIKit

/// Owns a notebook's manifest during editing: page list + the media / voice /
/// text elements layered over the ink. All mutations persist atomically through
/// `DocumentStore`.
@MainActor
@Observable
public final class NotebookEditorModel {
    public private(set) var manifest: NotebookManifest?
    /// The page most recently drawn on / tapped — the target for insertions.
    public var focusedPageID: UUID?

    private let notebookID: UUID
    private let store: DocumentStore

    public init(notebookID: UUID, store: DocumentStore) {
        self.notebookID = notebookID
        self.store = store
    }

    public var pages: [PageRecord] { manifest?.pages ?? [] }

    public func load() async {
        manifest = try? await store.manifest(for: notebookID)
        if focusedPageID == nil { focusedPageID = manifest?.pages.first?.id }
    }

    public func addPage(template: PageTemplate) async {
        manifest = try? await store.addPage(to: notebookID, template: template)
    }

    public func page(_ id: UUID?) -> PageRecord? {
        guard let id else { return nil }
        return manifest?.pages.first { $0.id == id }
    }

    // MARK: - Page settings & management

    public func updatePageSettings(
        pageID: UUID, template: PageTemplate? = nil, margin: PageMargin? = nil,
        paperColorHex: String? = nil, clearPaperColor: Bool = false
    ) async {
        manifest = try? await store.updatePage(
            notebook: notebookID, page: pageID, template: template, margin: margin,
            paperColorHex: paperColorHex, clearPaperColor: clearPaperColor
        )
    }

    public func deletePage(_ pageID: UUID) async {
        manifest = try? await store.deletePage(notebook: notebookID, page: pageID)
        if focusedPageID == pageID { focusedPageID = manifest?.pages.first?.id }
    }

    public func duplicatePage(_ pageID: UUID) async {
        manifest = try? await store.duplicatePage(notebook: notebookID, page: pageID)
    }

    public func movePage(from: Int, to: Int) async {
        manifest = try? await store.movePage(notebook: notebookID, from: from, to: to)
    }

    /// Inserts a page at `index`, inheriting `source`'s paper + margin (or the
    /// notebook default). Used by the page manager and infinite scroll.
    @discardableResult
    public func insertPage(at index: Int, inheriting source: UUID?) async -> UUID? {
        let template = page(source)?.template ?? manifest?.pages.first?.template ?? .blank
        let margin = page(source)?.margin ?? .default
        guard let result = try? await store.insertPage(
            notebook: notebookID, at: index, template: template, margin: margin
        ) else { return nil }
        manifest = result.manifest
        return result.page.id
    }

    /// Over-scroll past the last page → append a page inheriting the last one.
    @discardableResult
    public func appendInheritingLast() async -> UUID? {
        let count = manifest?.pages.count ?? 0
        return await insertPage(at: count, inheriting: manifest?.pages.last?.id)
    }

    /// Over-scroll above the first page → prepend a page inheriting the first.
    @discardableResult
    public func prependInheritingFirst() async -> UUID? {
        return await insertPage(at: 0, inheriting: manifest?.pages.first?.id)
    }

    // MARK: - Handwriting beautification

    /// OCRs the page's handwriting → returns the recognized text. The editor
    /// then cleans it with NOVA and calls `placeBeautifiedText` so the typeset
    /// text lands where the ink was and the ink is wiped — a true transform, not
    /// a floating textbox.
    public func recognizedHandwriting(pageID: UUID, drawing: PKDrawing) async -> String {
        await recognizeText(pageID: pageID, drawing: drawing)
    }

    /// Drops beautified text onto the page at `origin` (the ink's top-left), so
    /// it replaces the handwriting rather than appearing as a centered box.
    public func placeBeautifiedText(
        _ text: String, at origin: CGPoint, fontName: String, colorHex: String, pageID: UUID
    ) async {
        guard !text.isEmpty else { return }
        let width = min(PageGeometry.size.width - origin.x - 32, 560)
        let height = min(720, max(60, Double(text.count) / 42 * 26 + 44))
        let x = max(24, min(origin.x, PageGeometry.size.width - width - 24))
        let y = max(24, min(origin.y, PageGeometry.size.height - 60))
        await append(PageElement(
            kind: .text, x: x, y: y, width: width, height: height,
            text: text, fontName: fontName, textColorHex: colorHex
        ), to: pageID)
    }

    private var targetPageID: UUID? { focusedPageID ?? manifest?.pages.first?.id }

    /// A target page that actually exists in the current manifest. Used before
    /// writing a media blob so a stale/missing target never leaves an orphaned
    /// payload on disk with no element referencing it.
    private var existingTargetPageID: UUID? {
        guard let id = targetPageID, manifest?.pages.contains(where: { $0.id == id }) == true else { return nil }
        return id
    }

    // MARK: - Insertions

    private func center(width: Double, height: Double) -> (Double, Double) {
        let x = (PageGeometry.size.width - width) / 2
        let y = (PageGeometry.size.height - height) / 2
        return (max(0, x), max(0, y))
    }

    public func insertImage(_ data: Data, fileExtension: String) async {
        guard let pageID = existingTargetPageID,
              let filename = try? await store.saveMedia(data, notebook: notebookID, fileExtension: fileExtension) else { return }
        let size = Self.fittedImageSize(data)
        let (x, y) = center(width: size.width, height: size.height)
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

    public func insertFile(_ data: Data, displayName: String, fileExtension: String) async {
        guard let pageID = existingTargetPageID,
              let filename = try? await store.saveMedia(data, notebook: notebookID, fileExtension: fileExtension) else { return }
        let (x, y) = center(width: 260, height: 68)
        await append(PageElement(
            kind: .file, x: x, y: y, width: 260, height: 68,
            payloadFilename: filename, displayName: displayName
        ), to: pageID)
    }

    public func insertVoice(fileURL: URL, duration: TimeInterval) async {
        guard let pageID = existingTargetPageID,
              let data = try? Data(contentsOf: fileURL),
              let filename = try? await store.saveMedia(data, notebook: notebookID, fileExtension: "m4a") else { return }
        let (x, y) = center(width: 240, height: 52)
        await append(PageElement(
            kind: .audio, x: x, y: y, width: 240, height: 52,
            payloadFilename: filename, durationSeconds: duration
        ), to: pageID)
    }

    public func insertText(_ text: String, fontName: String, colorHex: String) async {
        guard let pageID = targetPageID, !text.isEmpty else { return }
        let width = 460.0
        let height = min(600, max(80, Double(text.count) / 40 * 26 + 60))
        let (x, y) = center(width: width, height: height)
        await append(PageElement(
            kind: .text, x: x, y: y, width: width, height: height,
            text: text, fontName: fontName, textColorHex: colorHex
        ), to: pageID)
    }

    private func append(_ element: PageElement, to pageID: UUID) async {
        guard var current = manifest,
              let index = current.pages.firstIndex(where: { $0.id == pageID }) else { return }
        current.pages[index].elements.append(element)
        manifest = current
        _ = try? await store.setElements(current.pages[index].elements, notebook: notebookID, page: pageID)
    }

    public func updateElement(_ element: PageElement, on pageID: UUID) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID }),
              let elementIndex = current.pages[pageIndex].elements.firstIndex(where: { $0.id == element.id }) else { return }
        current.pages[pageIndex].elements[elementIndex] = element
        manifest = current
        _ = try? await store.setElements(current.pages[pageIndex].elements, notebook: notebookID, page: pageID)
    }

    public func deleteElement(_ elementID: UUID, on pageID: UUID) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID }) else { return }
        current.pages[pageIndex].elements.removeAll { $0.id == elementID }
        manifest = current
        _ = try? await store.setElements(current.pages[pageIndex].elements, notebook: notebookID, page: pageID)
    }

    // MARK: - OCR (handwriting → text)

    /// Renders a page's ink to an image and recognizes the text — used by both
    /// "recognize handwriting" and circle-to-explain.
    public func recognizeText(pageID: UUID, drawing: PKDrawing) async -> String {
        // Render just the inked region (padded) at high scale — Vision recognizes
        // handwriting far better from a tight, high-resolution crop than from a
        // mostly-empty full page rendered at 2×.
        let inkBounds = drawing.bounds
        let region: CGRect
        if !inkBounds.isNull, !inkBounds.isEmpty {
            region = inkBounds.insetBy(dx: -24, dy: -24)
                .intersection(CGRect(origin: .zero, size: PageGeometry.size))
        } else {
            region = CGRect(origin: .zero, size: PageGeometry.size)
        }
        let image = drawing.image(from: region, scale: 3)
        return (try? await OCRService().recognizeText(in: image)) ?? ""
    }

    /// OCR any image directly (e.g. the magic pen's cropped region).
    public func ocr(image: UIImage) async -> String {
        (try? await OCRService().recognizeText(in: image)) ?? ""
    }

    public func mediaURL(filename: String) -> URL {
        store.mediaURL(notebook: notebookID, filename: filename)
    }

    private static func fittedImageSize(_ data: Data) -> CGSize {
        guard let image = UIImage(data: data) else { return CGSize(width: 300, height: 300) }
        let maxDimension: CGFloat = 380
        let aspect = image.size.width / max(1, image.size.height)
        if aspect >= 1 {
            return CGSize(width: maxDimension, height: maxDimension / aspect)
        }
        return CGSize(width: maxDimension * aspect, height: maxDimension)
    }
}
