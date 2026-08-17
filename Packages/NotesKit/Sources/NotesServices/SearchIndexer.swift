import Foundation
import NotesModels
import PencilKit
#if canImport(UIKit)
import UIKit
#endif

/// Reads notebooks so they can be searched.
///
/// Searching handwriting means recognising it, and recognising it is far too
/// slow to do per keystroke — so it is done once per page, when the page has
/// changed, and cached in the document package (`SearchIndex`). A page is read
/// again only when its ink is newer than the reading.
///
/// Everything here is best-effort by design. A page that fails to recognise is
/// an empty entry, not an error: search is a convenience, and it must never be
/// able to interrupt writing or block opening a notebook.
public actor SearchIndexer {
    /// Internal rather than private so `LibrarySearch` can read indexes off it —
    /// `private` is file-scoped, and the two halves of search live in two files.
    let store: DocumentStore
    private let ocr: OCRService

    /// Notebooks currently being read, so two callers asking at once (the search
    /// field and the launch pass) don't do the same work twice.
    private var inFlight: Set<UUID> = []

    public init(store: DocumentStore, ocr: OCRService = OCRService()) {
        self.store = store
        self.ocr = ocr
    }

    /// The longest side handed to Vision. A page rendered without a ceiling is
    /// tens of megapixels of mostly blank paper.
    static let maximumPageSide: CGFloat = 4000
    /// Hairline pens vanish into the antialiasing at page scale.
    static let minimumInkWidth: CGFloat = 2.4

    // MARK: - Reading one notebook

    /// Brings a notebook's index up to date and returns it.
    ///
    /// `force` re-reads every page even if it looks current — what the "Re-read
    /// this notebook" action in search uses when a result looks wrong.
    @discardableResult
    public func index(notebook id: UUID, force: Bool = false) async -> SearchIndex {
        guard !inFlight.contains(id) else { return await store.searchIndex(for: id) }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        guard let manifest = try? await store.manifest(for: id) else { return SearchIndex() }
        var index = await store.searchIndex(for: id)
        index.prune(toPages: manifest.pages.map(\.id))

        var changed = false
        for page in manifest.pages {
            let modified = await store.pageModifiedAt(notebook: id, page: page.id) ?? page.createdAt
            guard force || index.needsReindex(page.id, changedAt: modified) else { continue }
            let text = await read(page: page, notebook: id)
            index.set(text, for: page.id)
            changed = true
        }

        if changed || index.version != SearchIndex.currentVersion {
            index.version = SearchIndex.currentVersion
            try? await store.saveSearchIndex(index, for: id)
        }
        return index
    }

    /// Everything one page says: the words already typed on it, plus whatever
    /// recognition makes of the handwriting.
    private func read(page: PageRecord, notebook: UUID) async -> String {
        let recognized: String
        #if canImport(UIKit)
        recognized = await recognizeInk(page: page, notebook: notebook)
        #else
        recognized = ""
        #endif
        return Self.pageText(elements: page.elements, recognized: recognized)
    }

    #if canImport(UIKit)
    private func recognizeInk(page: PageRecord, notebook: UUID) async -> String {
        guard let data = await store.pageData(notebook: notebook, page: page.id),
              let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty else { return "" }
        let region = CGRect(origin: .zero, size: page.logicalSize)
        let image = InkRasterizer.recognitionImage(
            of: drawing,
            region: region,
            scale: Self.renderScale(for: page.logicalSize),
            minimumInkWidth: Self.minimumInkWidth
        )
        guard let lines = try? await ocr.recognize(in: image) else { return "" }
        return OCRService.assemble(lines)
    }
    #endif

    /// How much to magnify a page before reading it. Enough for ordinary
    /// handwriting to clear Vision's minimum, capped so a big page doesn't turn
    /// into a bitmap nothing can hold.
    static func renderScale(for size: CGSize) -> CGFloat {
        let longest = max(size.width, size.height, 1)
        return min(3, maximumPageSide / longest)
    }

    /// Joins a page's typed content and its recognised handwriting into the one
    /// string search runs against. Pure — the whole assembly is testable without
    /// Vision, a canvas or a document.
    ///
    /// Text boxes come FIRST because they are exact: what a text box says is what
    /// the page says, whereas recognition is a best guess. When both contain the
    /// query the exact copy is the one the snippet is cut from.
    public static func pageText(elements: [PageElement], recognized: String) -> String {
        var parts: [String] = []
        for element in elements {
            switch element.kind {
            case .text, .codeBlock:
                if let text = element.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty { parts.append(text) }
            case .link:
                // A link is findable by what it was CALLED as well as where it
                // goes — nobody remembers the URL of the paper they saved.
                if let name = element.displayName, !name.isEmpty { parts.append(name) }
                if let url = element.urlString, !url.isEmpty { parts.append(url) }
            case .file:
                if let name = element.displayName, !name.isEmpty { parts.append(name) }
            case .image, .audio, .tape, .fill, .unknown:
                continue
            }
        }
        let trimmedInk = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInk.isEmpty { parts.append(trimmedInk) }
        return parts.joined(separator: "\n")
    }
}
