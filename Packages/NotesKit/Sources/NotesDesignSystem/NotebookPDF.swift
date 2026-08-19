import ClassMateTheme
import NotesModels
import NotesServices
import PencilKit
import SwiftUI
import UIKit

/// Turning notebooks into something the rest of the world can open.
///
/// A note-taking app that can't hand a page to a teacher, a printer or a study
/// group is a diary. Everything here renders the page exactly as it looks in the
/// app — paper, rules, imported backgrounds, fills, ink, images, typeset text —
/// so what comes out is what was on screen, not a transcription of it.
public enum NotebookPDF {
    /// One rendered page, at its own size in PDF points.
    public struct RenderedPage: Sendable {
        public let size: CGSize
        public let image: UIImage

        public init(size: CGSize, image: UIImage) {
            self.size = size
            self.image = image
        }
    }

    /// Assembles rendered pages into a PDF.
    ///
    /// Each page keeps its OWN size: a notebook with an A4 scan dropped into the
    /// middle of it would otherwise letterbox or crop that page, and a PDF that
    /// crops the page is worse than no PDF.
    public static func data(
        from pages: [RenderedPage], title: String, author: String = "ClassNotes"
    ) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: author
        ]
        // The renderer needs a bounds up front; each page then overrides it with
        // its own, which is what `beginPage(withBounds:)` is for.
        let first = pages.first?.size ?? CGSize(width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: first), format: format
        )
        return renderer.pdfData { context in
            for page in pages {
                let bounds = CGRect(origin: .zero, size: page.size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                page.image.draw(in: bounds)
            }
        }
    }

    /// A filename that survives a share sheet: the notebook's own title, with
    /// everything a file system objects to taken out.
    public static func filename(for title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "Notebook" : cleaned
        return "\(name).pdf"
    }
}

/// The page as it looks, composited for export: paper, any imported background,
/// the fills under the ink, the ink, and everything placed on top.
///
/// The viewer, the editor and the exporter each used to build this stack
/// themselves; a layer added in one was a layer missing from the others.
public struct PageCompositeView: View {
    let page: PageRecord
    let cover: CoverPaper?
    let ink: UIImage?
    let background: UIImage?
    let size: CGSize
    let mediaURL: (String) -> URL

    public init(
        page: PageRecord,
        cover: CoverPaper?,
        ink: UIImage?,
        background: UIImage?,
        size: CGSize,
        mediaURL: @escaping (String) -> URL
    ) {
        self.page = page
        self.cover = cover
        self.ink = ink
        self.background = background
        self.size = size
        self.mediaURL = mediaURL
    }

    public var body: some View {
        ZStack {
            PagePaperView(page: page, cover: cover)
            if let background {
                Image(uiImage: background).resizable().scaledToFit()
            }
            // Everything except tape renders BELOW the ink — a stroke drawn
            // over an image or a file is visible on top of it, matching the
            // editor. Fills travel with this pass too: a fill's polygon
            // already stops exactly where the ink stopped the flood (see
            // `FillRegionView`), so it reads as under the ink either way.
            PageContentView(
                elements: page.elements,
                displaySize: size,
                logicalSize: page.logicalSize,
                mediaURL: mediaURL,
                layer: .belowInk
            )
            if let ink {
                Image(uiImage: ink).resizable().scaledToFit()
            }
            // Tape stays above the ink: hiding what's underneath it is the
            // entire point of tape.
            PageContentView(
                elements: page.elements,
                displaySize: size,
                logicalSize: page.logicalSize,
                mediaURL: mediaURL,
                layer: .aboveInk
            )
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Loads a notebook off disk and renders it, page by page, into a PDF.
///
/// Works from the LIBRARY, without opening the editor: the ink is read from the
/// document package rather than from a live canvas, so exporting doesn't depend
/// on which pages happen to be on screen.
@MainActor
public struct NotebookExporter {
    private let store: DocumentStore
    private let theme: ThemeSpec
    private let paperTone: PaperTone

    public init(store: DocumentStore, theme: ThemeSpec, paperTone: PaperTone) {
        self.store = store
        self.theme = theme
        self.paperTone = paperTone
    }

    /// Renders the whole notebook. `pageIDs` limits it to a selection.
    public func pdf(
        notebook: Notebook, pageIDs: Set<UUID>? = nil, scale: CGFloat = 2
    ) async -> Data? {
        guard let manifest = try? await store.manifest(for: notebook.id) else { return nil }
        let wanted = manifest.pages.filter { pageIDs?.contains($0.id) ?? true }
        guard !wanted.isEmpty else { return nil }

        var rendered: [NotebookPDF.RenderedPage] = []
        for page in wanted {
            guard let image = await render(page: page, of: notebook, scale: scale) else { continue }
            rendered.append(NotebookPDF.RenderedPage(size: page.logicalSize, image: image))
        }
        guard !rendered.isEmpty else { return nil }
        return NotebookPDF.data(from: rendered, title: notebook.title)
    }

    /// Writes the PDF to a temporary file and hands back the URL, which is what a
    /// share sheet wants — sharing `Data` gives the recipient a nameless blob.
    public func pdfFile(notebook: Notebook, pageIDs: Set<UUID>? = nil) async -> URL? {
        guard let data = await pdf(notebook: notebook, pageIDs: pageIDs) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(NotebookPDF.filename(for: notebook.title))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// One downscaled "contact sheet" image — every page (up to `maxPages`)
    /// tiled into a grid — for handing the WHOLE notebook to a vision model in
    /// one attachment.
    ///
    /// The backend only accepts one `imageBase64` per turn, so there's no way to
    /// send an actual multi-page PDF — this is the same "a picture, not a
    /// document format" idea the AI snip already relies on (`NovaSnip`), scaled
    /// up to the whole notebook instead of one crop. Tiles are rendered small
    /// and JPEG-compressed, the same "shrink it first so it stays affordable"
    /// posture the snip flow uses.
    public func contactSheet(
        notebook: Notebook, pageIDs: Set<UUID>? = nil, maxPages: Int = 24
    ) async -> (image: Data, pageCount: Int)? {
        guard let manifest = try? await store.manifest(for: notebook.id) else { return nil }
        let wanted = manifest.pages.filter { pageIDs?.contains($0.id) ?? true }
        guard !wanted.isEmpty else { return nil }
        let capped = Array(wanted.prefix(maxPages))

        let tileWidth: CGFloat = 320
        var tiles: [UIImage] = []
        for page in capped {
            guard let full = await render(page: page, of: notebook, scale: 1) else { continue }
            let tileHeight = tileWidth * (full.size.height / max(full.size.width, 1))
            let tile = UIGraphicsImageRenderer(size: CGSize(width: tileWidth, height: tileHeight))
                .image { _ in full.draw(in: CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight)) }
            tiles.append(tile)
        }
        guard !tiles.isEmpty else { return nil }

        let columns = min(4, tiles.count)
        let rows = Int((Double(tiles.count) / Double(columns)).rounded(.up))
        let spacing: CGFloat = 8
        let maxTileHeight = tiles.map(\.size.height).max() ?? tileWidth
        let sheetSize = CGSize(
            width: CGFloat(columns) * tileWidth + CGFloat(columns + 1) * spacing,
            height: CGFloat(rows) * maxTileHeight + CGFloat(rows + 1) * spacing
        )
        let sheet = UIGraphicsImageRenderer(size: sheetSize).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: sheetSize))
            for (index, tile) in tiles.enumerated() {
                let x = spacing + CGFloat(index % columns) * (tileWidth + spacing)
                let y = spacing + CGFloat(index / columns) * (maxTileHeight + spacing)
                tile.draw(in: CGRect(x: x, y: y, width: tile.size.width, height: tile.size.height))
            }
        }
        guard let data = sheet.jpegData(compressionQuality: 0.7) else { return nil }
        return (data, capped.count)
    }

    private func render(page: PageRecord, of notebook: Notebook, scale: CGFloat) async -> UIImage? {
        let size = page.logicalSize
        let ink = await inkImage(page: page, notebook: notebook.id, scale: scale)
        let background = await backgroundImage(page: page, notebook: notebook.id)
        let content = PageCompositeView(
            page: page,
            cover: notebook.usesCoverPage ? notebook.coverPaper : nil,
            ink: ink,
            background: background,
            size: size,
            mediaURL: { store.mediaURL(notebook: notebook.id, filename: $0) }
        )
        .environment(\.theme, theme)
        .environment(\.paperTone, paperTone)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.uiImage
    }

    private func inkImage(page: PageRecord, notebook: UUID, scale: CGFloat) async -> UIImage? {
        guard let data = await store.pageData(notebook: notebook, page: page.id),
              let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty else { return nil }
        return drawing.image(from: CGRect(origin: .zero, size: page.logicalSize), scale: scale)
    }

    private func backgroundImage(page: PageRecord, notebook: UUID) async -> UIImage? {
        guard let filename = page.backgroundPayloadFilename,
              let data = await store.mediaData(notebook: notebook, filename: filename)
        else { return nil }
        return UIImage(data: data)
    }
}
