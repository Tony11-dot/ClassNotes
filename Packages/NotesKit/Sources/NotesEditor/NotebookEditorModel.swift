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
        let bounds = CGRect(origin: .zero, size: PageGeometry.size)
        let image = drawing.image(from: bounds, scale: 2)
        return (try? await OCRService().recognizeText(in: image)) ?? ""
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
