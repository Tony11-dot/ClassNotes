import ClassMateTheme
import Foundation
import NotesModels
import NotesServices
import Observation
import PencilKit
import SwiftUI
import UIKit

/// Owns a notebook's manifest during editing: page list plus the media / voice /
/// text / tape elements layered over the ink. All mutations persist atomically
/// through `DocumentStore`.
@MainActor
@Observable
public final class NotebookEditorModel {
    /// `internal(set)` because the insertion half of this model lives in its own
    /// file; nothing outside the editor may rewrite the manifest.
    public internal(set) var manifest: NotebookManifest?
    /// The page most recently drawn on / tapped — the target for insertions.
    public var focusedPageID: UUID?

    let notebookID: UUID
    let store: DocumentStore

    public init(notebookID: UUID, store: DocumentStore) {
        self.notebookID = notebookID
        self.store = store
    }

    public var pages: [PageRecord] { manifest?.pages ?? [] }

    /// Loads the manifest. `coverStyle` is passed for a notebook that should have
    /// a cover page: a notebook written before manifest v7 gets its cover added
    /// here, once, and everything after that is an ordinary page list.
    public func load(coverStyle: PageStyle? = nil) async {
        if let coverStyle {
            manifest = try? await store.ensureCoverPage(notebook: notebookID, style: coverStyle)
        }
        if manifest == nil {
            manifest = try? await store.manifest(for: notebookID)
        }
        if focusedPageID == nil { focusedPageID = manifest?.pages.first?.id }
    }

    /// The cover page, when this notebook has one.
    public var coverPage: PageRecord? { manifest?.coverPage }

    public func addPage(template: PageTemplate) async {
        manifest = try? await store.addPage(to: notebookID, template: template)
    }

    public func page(_ id: UUID?) -> PageRecord? {
        guard let id else { return nil }
        return manifest?.pages.first { $0.id == id }
    }

    /// The page an insertion lands on, and its logical size.
    public var focusedPage: PageRecord? {
        page(focusedPageID) ?? manifest?.pages.first
    }

    public var focusedPageSize: CGSize {
        focusedPage?.logicalSize ?? PageGeometry.size
    }

    // MARK: - Page settings & management

    public func updatePageSettings(
        pageID: UUID, template: PageTemplate? = nil, margin: PageMargin? = nil,
        paperColorHex: String? = nil, clearPaperColor: Bool = false,
        lineColorHex: String? = nil, clearLineColor: Bool = false,
        lineSpacingSteps: Int? = nil,
        pageSize: PageSize? = nil, orientation: PageOrientation? = nil
    ) async {
        manifest = try? await store.updatePage(
            notebook: notebookID, page: pageID, template: template, margin: margin,
            paperColorHex: paperColorHex, clearPaperColor: clearPaperColor,
            lineColorHex: lineColorHex, clearLineColor: clearLineColor,
            lineSpacingSteps: lineSpacingSteps,
            pageSize: pageSize, orientation: orientation
        )
    }

    /// Applies a whole style to one page — what the page-settings sheet edits.
    public func updatePageSettings(pageID: UUID, style: PageStyle) async {
        await updatePageSettings(
            pageID: pageID,
            template: style.template,
            margin: style.margin,
            paperColorHex: style.paperColorHex,
            clearPaperColor: style.paperColorHex == nil,
            lineColorHex: style.lineColorHex,
            clearLineColor: style.lineColorHex == nil,
            lineSpacingSteps: style.lineSpacingSteps,
            pageSize: style.pageSize,
            orientation: style.orientation
        )
    }

    /// Copies one page's paper, rules and geometry onto every page.
    public func applyStyleToAllPages(from pageID: UUID) async {
        manifest = try? await store.applyStyle(of: pageID, toAllPagesOf: notebookID)
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

    /// Inserts a page at `index`, inheriting `source`'s whole style (or the first
    /// page's). Used by the page manager and infinite scroll.
    @discardableResult
    public func insertPage(at index: Int, inheriting source: UUID?) async -> UUID? {
        let style = page(source)?.style
            ?? manifest?.pages.first?.style
            ?? PageStyle(template: .blank)
        guard let result = try? await store.insertPage(
            notebook: notebookID, at: index, style: style
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

    /// OCRs the page's handwriting → returns the recognized text. Used by the
    /// explicit "handwriting → text" command; real-time beautification goes
    /// through `LiveBeautifier` and `apply(plan:)`.
    public func recognizedHandwriting(pageID: UUID, drawing: PKDrawing) async -> String {
        await recognizeText(pageID: pageID, drawing: drawing)
    }

    /// Commits one beautification pass: new typeset runs are added, runs the
    /// student continued are rewritten, all in a single manifest write.
    ///
    /// Returns the page's elements as they were BEFORE the pass, which is what
    /// Undo restores. A pass both inserts and rewrites, so "remove what was
    /// inserted" is not enough to take one back — the rewritten runs have to go
    /// back to the words they held before the student carried on writing.
    @discardableResult
    func apply(plan: BeautifyPlan, to pageID: UUID) async -> [PageElement] {
        guard !plan.isEmpty, var current = manifest,
              let index = current.pages.firstIndex(where: { $0.id == pageID }) else { return [] }
        var elements = current.pages[index].elements
        let before = elements
        for updated in plan.updates {
            if let existing = elements.firstIndex(where: { $0.id == updated.id }) {
                elements[existing] = updated
            } else {
                elements.append(updated)
            }
        }
        elements.append(contentsOf: plan.inserts)
        current.pages[index].elements = elements
        manifest = current
        _ = try? await store.setElements(elements, notebook: notebookID, page: pageID)
        return before
    }

    /// Puts a page's elements back exactly as they were — the undo half of
    /// `apply(plan:to:)`.
    func restoreElements(_ elements: [PageElement], on pageID: UUID) async {
        guard var current = manifest,
              let index = current.pages.firstIndex(where: { $0.id == pageID }) else { return }
        current.pages[index].elements = elements
        manifest = current
        _ = try? await store.setElements(elements, notebook: notebookID, page: pageID)
    }

    /// Drops beautified text onto the page at `origin` (the ink's top-left), so
    /// it replaces the handwriting rather than appearing as a centered box.
    public func placeBeautifiedText(
        _ text: String, at origin: CGPoint, fontName: String, colorHex: String, pageID: UUID
    ) async {
        guard !text.isEmpty else { return }
        let pageSize = page(pageID)?.logicalSize ?? PageGeometry.size
        let width = min(pageSize.width - origin.x - 32, pageSize.width * 0.73)
        let height = min(pageSize.height * 0.7, max(60, Double(text.count) / 42 * 26 + 44))
        let x = max(24, min(origin.x, pageSize.width - width - 24))
        let y = max(24, min(origin.y, pageSize.height - 60))
        await append(PageElement(
            kind: .text, x: x, y: y, width: width, height: height,
            text: text, fontName: fontName, textColorHex: colorHex
        ), to: pageID)
    }

    var targetPageID: UUID? { focusedPageID ?? manifest?.pages.first?.id }

    /// A target page that actually exists in the current manifest. Used before
    /// writing a media blob so a stale/missing target never leaves an orphaned
    /// payload on disk with no element referencing it.
    var existingTargetPageID: UUID? {
        guard let id = targetPageID, manifest?.pages.contains(where: { $0.id == id }) == true else { return nil }
        return id
    }

    // MARK: - Element plumbing

    func append(_ element: PageElement, to pageID: UUID) async {
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
    public func recognizeText(
        pageID: UUID, drawing: PKDrawing, language: String = BeautifyLanguage.default.code
    ) async -> String {
        // Render just the inked region (padded) at high scale — Vision recognizes
        // handwriting far better from a tight, high-resolution crop than from a
        // mostly-empty full page rendered at 2×.
        let pageSize = page(pageID)?.logicalSize ?? PageGeometry.size
        let inkBounds = drawing.bounds
        let region: CGRect
        if !inkBounds.isNull, !inkBounds.isEmpty {
            region = inkBounds.insetBy(dx: -24, dy: -24)
                .intersection(CGRect(origin: .zero, size: pageSize))
        } else {
            region = CGRect(origin: .zero, size: pageSize)
        }
        let image = drawing.image(from: region, scale: 3)
        return (try? await OCRService().recognizeText(in: image, languages: [language])) ?? ""
    }

    /// OCR any image directly (e.g. the magic pen's cropped region).
    public func ocr(image: UIImage) async -> String {
        (try? await OCRService().recognizeText(in: image)) ?? ""
    }

    public func mediaURL(filename: String) -> URL {
        store.mediaURL(notebook: notebookID, filename: filename)
    }

    static func fittedImageSize(_ data: Data, in pageSize: CGSize) -> CGSize {
        let fallback = min(pageSize.width, pageSize.height) * 0.4
        guard let image = UIImage(data: data), image.size.height > 0 else {
            return CGSize(width: fallback, height: fallback)
        }
        let maxDimension = min(pageSize.width * 0.62, 420)
        let aspect = image.size.width / max(1, image.size.height)
        if aspect >= 1 {
            return CGSize(width: maxDimension, height: maxDimension / aspect)
        }
        return CGSize(width: maxDimension * aspect, height: maxDimension)
    }
}
