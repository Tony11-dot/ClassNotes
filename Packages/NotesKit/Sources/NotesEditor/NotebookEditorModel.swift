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
    /// A write that didn't reach disk and is being retried — shown by the editor.
    /// See `NotebookEditorModelSafety.swift`.
    public internal(set) var saveProblem: SaveProblem?
    /// The pages the last delete took, for the editor's Undo toast.
    public internal(set) var recentlyDeletedPages: [UUID] = []
    /// How far a running PDF / photo import has got, for the editor's pill.
    public internal(set) var importProgress: ImportProgress?
    /// Element lists the editor shows but the disk doesn't have yet.
    var unsavedElements: [UUID: [PageElement]] = [:]
    var retryTask: Task<Void, Never>?

    let notebookID: UUID
    let store: DocumentStore

    public init(notebookID: UUID, store: DocumentStore) {
        self.notebookID = notebookID
        self.store = store
    }

    public var pages: [PageRecord] { manifest?.pages ?? [] }

    /// Loads the manifest. A notebook that should have a cover page (`hasCover`)
    /// and was written before manifest v7 gets its cover added here, once, and
    /// everything after that is an ordinary page list.
    ///
    /// A notebook of this device's whose package is gone entirely opens onto a
    /// fresh page in `style`. Reading a missing notebook creates nothing anywhere
    /// else (`DocumentStore.manifest(for:)`), so the editor has to ask for it.
    public func load(style: PageStyle, hasCover: Bool) async {
        try? await store.createDocumentIfMissing(id: notebookID, style: style, includesCover: hasCover)
        await load(coverStyle: hasCover ? style : nil)
    }

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
        // Pages deleted more than the grace period ago go for good — here, when
        // the notebook is opened, so it never costs anything at launch.
        _ = try? await store.purgeExpiredPages(notebook: notebookID)
    }

    /// The cover page, when this notebook has one.
    public var coverPage: PageRecord? { manifest?.coverPage }

    public func addPage(template: PageTemplate) async {
        await commit { [store, notebookID] in try await store.addPage(to: notebookID, template: template) }
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
        await commit { [store, notebookID] in
            try await store.updatePage(
                notebook: notebookID, page: pageID, template: template, margin: margin,
                paperColorHex: paperColorHex, clearPaperColor: clearPaperColor,
                lineColorHex: lineColorHex, clearLineColor: clearLineColor,
                lineSpacingSteps: lineSpacingSteps,
                pageSize: pageSize, orientation: orientation
            )
        }
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
        await commit { [store, notebookID] in try await store.applyStyle(of: pageID, toAllPagesOf: notebookID) }
    }

    /// Deletes a page into the notebook's trash; `undoRecentDeletion` brings it
    /// back, and so does the page manager's Recently Deleted list.
    public func deletePage(_ pageID: UUID) async {
        await deletePages([pageID])
    }

    /// Deletes several pages at once — the page manager's Select tool. Each
    /// goes through the same single-page delete, in page order, so undoing
    /// them in reverse puts every one back exactly where it was.
    public func deletePages(_ pageIDs: Set<UUID>) async {
        let ordered = pages.map(\.id).filter { pageIDs.contains($0) }
        var deleted: [UUID] = []
        for id in ordered {
            let done = await commit { [store, notebookID] in
                try await store.deletePage(notebook: notebookID, page: id)
            }
            if done { deleted.append(id) }
        }
        recentlyDeletedPages = deleted
        if let focusedPageID, pageIDs.contains(focusedPageID) {
            self.focusedPageID = manifest?.pages.first?.id
        }
    }

    /// Flags or unflags a page. A duplicate of a bookmarked page is deliberately
    /// NOT bookmarked — the flag marks a place, and a copy isn't that place.
    public func toggleBookmark(_ pageID: UUID, name: String? = nil) async {
        guard let page = page(pageID) else { return }
        await commit { [store, notebookID] in
            try await store.setBookmark(
                notebook: notebookID, page: pageID, isBookmarked: !page.isBookmarked, name: name
            )
        }
    }

    /// The flagged pages in page order, for the bookmark jump menu.
    public var bookmarkedPages: [PageRecord] { manifest?.bookmarkedPages ?? [] }

    /// What a bookmark is called in the jump list: the name the user gave it, or
    /// the page's own number.
    public func bookmarkLabel(for page: PageRecord) -> String {
        if let name = page.bookmarkName, !name.isEmpty { return name }
        if page.isCover { return "Cover" }
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return "Page" }
        return "Page \(pages.prefix(index + 1).filter { !$0.isCover }.count)"
    }

    public func duplicatePage(_ pageID: UUID) async {
        await commit { [store, notebookID] in try await store.duplicatePage(notebook: notebookID, page: pageID) }
    }

    public func movePage(from: Int, to: Int) async {
        await commit { [store, notebookID] in try await store.movePage(notebook: notebookID, from: from, to: to) }
    }

    /// Inserts a page at `index`, inheriting `source`'s whole style (or the first
    /// page's). Used by the page manager and infinite scroll.
    @discardableResult
    public func insertPage(at index: Int, inheriting source: UUID?) async -> UUID? {
        let style = page(source)?.style
            ?? manifest?.pages.first?.style
            ?? PageStyle(template: .blank)
        guard await flushUnsavedElements() else { return nil }
        do {
            let result = try await store.insertPage(notebook: notebookID, at: index, style: style)
            manifest = result.manifest
            return result.page.id
        } catch {
            report(error)
            return nil
        }
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
    /// Returns the page's elements either side of the pass. A pass both inserts
    /// new runs and rewrites existing ones, so "remove what was inserted" is not
    /// enough to take one back — the rewritten runs have to go back to the words
    /// they held before the student carried on writing, and Redo has to be able
    /// to put the whole pass back.
    @discardableResult
    func apply(plan: BeautifyPlan, to pageID: UUID) async -> BeautifyElements {
        guard !plan.isEmpty, var current = manifest,
              let index = current.pages.firstIndex(where: { $0.id == pageID }) else {
            return BeautifyElements()
        }
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
        await saveElements(elements, notebook: notebookID, page: pageID)
        return BeautifyElements(before: before, after: elements)
    }

    /// Puts a page's elements back exactly as they were — the undo half of
    /// `apply(plan:to:)`.
    func restoreElements(_ elements: [PageElement], on pageID: UUID) async {
        guard var current = manifest,
              let index = current.pages.firstIndex(where: { $0.id == pageID }) else { return }
        current.pages[index].elements = elements
        manifest = current
        await saveElements(elements, notebook: notebookID, page: pageID)
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
        await saveElements(current.pages[index].elements, notebook: notebookID, page: pageID)
    }

    public func updateElement(_ element: PageElement, on pageID: UUID) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID }),
              let elementIndex = current.pages[pageIndex].elements.firstIndex(where: { $0.id == element.id }) else { return }
        current.pages[pageIndex].elements[elementIndex] = element
        manifest = current
        await saveElements(current.pages[pageIndex].elements, notebook: notebookID, page: pageID)
    }

    /// Adds a flooded region. Fills go in FIRST in the element list so anything
    /// placed on the page later — a text box, a photo, a strip of tape — draws
    /// over the colour rather than under it.
    public func insertFill(
        outline: [CGPoint], holes: [[CGPoint]] = [], colorHex: String, on pageID: UUID
    ) async {
        guard outline.count > 2, var current = manifest,
              let index = current.pages.firstIndex(where: { $0.id == pageID }) else { return }
        let box = outline.dropFirst().reduce(
            CGRect(origin: outline[0], size: .zero)
        ) { $0.union(CGRect(origin: $1, size: .zero)) }
        let element = PageElement(
            kind: .fill,
            x: box.minX, y: box.minY, width: box.width, height: box.height,
            colorHex: colorHex,
            points: outline.map(PagePoint.init),
            holes: holes.map { $0.map(PagePoint.init) }
        )
        current.pages[index].elements.insert(element, at: 0)
        manifest = current
        await saveElements(
            current.pages[index].elements, notebook: notebookID, page: pageID
        )
    }

    /// Copies an element, offset so the copy is visible rather than exactly on
    /// top of what it was copied from.
    public func duplicateElement(_ elementID: UUID, on pageID: UUID, offset: CGSize) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID }),
              let source = current.pages[pageIndex].elements.first(where: { $0.id == elementID })
        else { return }
        var copy = source.moved(by: offset)
        copy.id = UUID()
        current.pages[pageIndex].elements.append(copy)
        manifest = current
        await saveElements(
            current.pages[pageIndex].elements, notebook: notebookID, page: pageID
        )
    }

    /// Shifts an element, and any path it carries, by `offset`.
    public func moveElement(_ elementID: UUID, on pageID: UUID, by offset: CGSize) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID }),
              let elementIndex = current.pages[pageIndex].elements
                .firstIndex(where: { $0.id == elementID })
        else { return }
        // A fill's outline moves with it; tape's path is relative to its frame
        // and moves by itself (`PageElement.moved`).
        current.pages[pageIndex].elements[elementIndex] =
            current.pages[pageIndex].elements[elementIndex].moved(by: offset)
        manifest = current
        await saveElements(
            current.pages[pageIndex].elements, notebook: notebookID, page: pageID
        )
    }

    /// Applies an arbitrary affine transform to an element's frame and any
    /// path it carries — used by lasso resize, which SCALES a whole selection
    /// rather than just shifting it the way `moveElement` does.
    public func transformElement(_ elementID: UUID, on pageID: UUID, by transform: CGAffineTransform) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID }),
              let elementIndex = current.pages[pageIndex].elements
                .firstIndex(where: { $0.id == elementID })
        else { return }
        current.pages[pageIndex].elements[elementIndex] =
            current.pages[pageIndex].elements[elementIndex].transformed(by: transform)
        manifest = current
        await saveElements(
            current.pages[pageIndex].elements, notebook: notebookID, page: pageID
        )
    }

    public func deleteElement(_ elementID: UUID, on pageID: UUID) async {
        guard var current = manifest,
              let pageIndex = current.pages.firstIndex(where: { $0.id == pageID }) else { return }
        current.pages[pageIndex].elements.removeAll { $0.id == elementID }
        manifest = current
        await saveElements(current.pages[pageIndex].elements, notebook: notebookID, page: pageID)
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
