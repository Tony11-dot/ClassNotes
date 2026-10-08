import Foundation
import ImageIO
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
    /// The language handwriting is read in — the one the user picked for
    /// beautification. Asked for on every pass rather than captured once, so a
    /// change in Settings applies to the next page read.
    ///
    /// This used to be absent and recognition ran on `OCRService`'s `en-US`
    /// default: Hebrew (or Arabic, Russian…) notes went through the English
    /// model, came back as noise, and a search for any word in them found nothing.
    private let language: @Sendable () async -> String

    /// Notebooks currently being read, so two callers asking at once (the search
    /// field and the launch pass) don't do the same work twice.
    private var inFlight: Set<UUID> = []

    public init(
        store: DocumentStore,
        ocr: OCRService = OCRService(),
        language: @escaping @Sendable () async -> String = { BeautifyLanguage.default.code }
    ) {
        self.store = store
        self.ocr = ocr
        self.language = language
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
        // An index read in another language is a reading of the wrong words:
        // every page is read again, once, in the language now chosen.
        let language = await self.language()
        let relanguaged = index.isRead(in: language) == false
        // An index from before backgrounds were read has every imported page
        // indexed as if it were blank paper; those pages are read once more.
        let unreadBackgrounds = index.version < SearchIndex.backgroundsVersion

        var changed = relanguaged
        for page in manifest.pages {
            let modified = await store.pageModifiedAt(notebook: id, page: page.id) ?? page.createdAt
            let backgroundUnread = unreadBackgrounds && page.backgroundPayloadFilename != nil
            guard force || relanguaged || backgroundUnread
                    || index.needsReindex(page.id, changedAt: modified) else { continue }
            let text = await read(page: page, notebook: id, language: language)
            index.set(text, for: page.id)
            changed = true
        }
        index.language = language

        if changed || index.version != SearchIndex.currentVersion {
            index.version = SearchIndex.currentVersion
            try? await store.saveSearchIndex(index, for: id)
        }
        return index
    }

    /// Everything one page says: the words already typed on it, plus whatever
    /// recognition makes of the handwriting.
    private func read(page: PageRecord, notebook: UUID, language: String) async -> String {
        let recognized: String
        let printed: String
        #if canImport(UIKit)
        recognized = await recognizeInk(page: page, notebook: notebook, language: language)
        printed = await recognizeBackground(page: page, notebook: notebook, language: language)
        #else
        recognized = ""
        printed = ""
        #endif
        return Self.pageText(elements: page.elements, recognized: recognized, printed: printed)
    }

    #if canImport(UIKit)
    private func recognizeInk(page: PageRecord, notebook: UUID, language: String) async -> String {
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
        guard let lines = try? await ocr.recognize(in: image, languages: [language]) else { return "" }
        return OCRService.assemble(lines)
    }

    /// The words printed on an imported page — a PDF page, a scan, a photo —
    /// which is rendered into the page's background image at import. Without
    /// this, a 300-page textbook imported as a PDF could not be found by a
    /// single word in it. Read with the same Vision pass as handwriting, from
    /// an image decoded straight to a bounded size.
    private func recognizeBackground(page: PageRecord, notebook: UUID, language: String) async -> String {
        guard let filename = page.backgroundPayloadFilename,
              let image = Self.backgroundImage(at: store.mediaURL(notebook: notebook, filename: filename))
        else { return "" }
        guard let lines = try? await ocr.recognize(in: image, languages: [language]) else { return "" }
        return OCRService.assemble(lines)
    }

    static func backgroundImage(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPageSide
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
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
    public static func pageText(elements: [PageElement], recognized: String, printed: String = "") -> String {
        var parts = elements.flatMap(searchableText(of:))
        let trimmedInk = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInk.isEmpty { parts.append(trimmedInk) }
        // What was printed on an imported page comes last: the user's own
        // words on top of a handout are what they'll most often search for.
        let trimmedPrint = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrint.isEmpty { parts.append(trimmedPrint) }
        return parts.joined(separator: "\n")
    }

    /// The words one element contributes: what a text or code box says, a
    /// graph's expressions, a link's name and address, a file's name.
    static func searchableText(of element: PageElement) -> [String] {
        let candidates: [String?]
        switch element.kind {
        case .text, .codeBlock:
            candidates = [element.text]
        case .functionPlot:
            candidates = [
                element.functionExpression,
                element.functionSecondaryExpression,
                element.functionTertiaryExpression
            ]
        case .link:
            // A link is findable by what it was CALLED as well as where it
            // goes — nobody remembers the URL of the paper they saved.
            candidates = [element.displayName, element.urlString]
        case .file:
            candidates = [element.displayName]
        case .image, .audio, .tape, .fill, .unknown:
            candidates = []
        }
        return candidates.compactMap { text in
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
