import ClassMateTheme
import CoreGraphics
import Foundation

/// On-disk description of one notebook document package (`<uuid>.cmnote/`):
/// `manifest.json` (this type) plus `pages/<pageID>.drawing` blobs and the
/// `media/` payloads referenced by page elements. SwiftData never sees ink.
public struct NotebookManifest: Codable, Sendable, Equatable {
    /// v2 adds `PageRecord.elements` (images / voice notes / typeset text).
    /// v3 adds `PageRecord.margin`. v4 adds `PageRecord.paperColorHex` (a chosen
    /// page color). v5 adds `PageRecord.backgroundPayloadFilename` (an imported
    /// PDF page rendered as the page background, drawn on with all tools).
    /// v6 adds page size + orientation, the line color and the line spacing, so a
    /// notebook can be A4 landscape with blue rules. v7 adds `PageRecord.isCover`:
    /// the notebook's cover is page one and is drawn on like any other page.
    /// v8 adds `PageRecord.isBookmarked` — a flagged page, jumped to from the page
    /// manager. Older manifests decode fine — every added field is optional /
    /// defaulted, and `DocumentStore.ensureCoverPage` is what gives a pre-v7
    /// notebook its cover page, exactly once.
    public static let currentVersion = 8

    /// The version at which the cover became page one.
    ///
    /// `ensureCoverPage` keys off THIS, never off `currentVersion`. Those were the
    /// same number for exactly as long as v7 was the newest manifest, and the
    /// moment another field was added every v7 notebook would have looked
    /// "pre-cover" again — handing a cover back to everyone who had deliberately
    /// deleted theirs, on the next launch after the upgrade.
    public static let coverPageVersion = 7

    public var version: Int
    public var pages: [PageRecord]

    public init(version: Int = NotebookManifest.currentVersion, pages: [PageRecord]) {
        self.version = version
        self.pages = pages
    }

    /// The cover page, if this notebook has one.
    public var coverPage: PageRecord? { pages.first { $0.isCover } }
    public var hasCoverPage: Bool { coverPage != nil }

    /// The flagged pages, in page order — what the page manager's bookmark filter
    /// and the "jump to a bookmark" list are built from.
    public var bookmarkedPages: [PageRecord] { pages.filter(\.isBookmarked) }
}

public struct PageRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var template: PageTemplate
    public var createdAt: Date
    public var elements: [PageElement]
    public var margin: PageMargin
    /// Chosen page (paper) color. `nil` = auto — the theme's paper color.
    public var paperColorHex: String?
    /// An imported PDF/image page rendered to a PNG in the package's `media/`
    /// folder, shown as the page background beneath the ink. `nil` = normal paper.
    public var backgroundPayloadFilename: String?
    /// Paper size + direction. Pages written before v6 are `classic` portrait, so
    /// their ink keeps its original 768×1024 geometry.
    public var pageSize: PageSize
    public var orientation: PageOrientation
    /// The rule / grid / dot color. `nil` = auto (theme separator, or a soft light
    /// rule on dark paper).
    public var lineColorHex: String?
    /// Line-spacing step, `PageLineSpacing.range`.
    public var lineSpacingSteps: Int
    /// The notebook's cover, as page one. Its "paper" is the cover artwork
    /// (`CoverPaper`, from the notebook's design + color + title) instead of a
    /// paper template, and it takes ink exactly like every other page.
    public var isCover: Bool
    /// Flagged by the user to come back to. Shown as a ribbon on the page
    /// manager's thumbnail and listed in the bookmark jump menu.
    public var isBookmarked: Bool
    /// What the user called this bookmark. `nil` = just the page number, which is
    /// what a bookmark dropped with one tap gets.
    public var bookmarkName: String?

    public init(
        id: UUID = UUID(),
        template: PageTemplate,
        createdAt: Date = .now,
        elements: [PageElement] = [],
        margin: PageMargin = .default,
        paperColorHex: String? = nil,
        backgroundPayloadFilename: String? = nil,
        pageSize: PageSize = .classic,
        orientation: PageOrientation = .portrait,
        lineColorHex: String? = nil,
        lineSpacingSteps: Int = PageLineSpacing.default,
        isCover: Bool = false,
        isBookmarked: Bool = false,
        bookmarkName: String? = nil
    ) {
        self.id = id
        self.template = template
        self.createdAt = createdAt
        self.elements = elements
        self.margin = margin
        self.paperColorHex = paperColorHex
        self.backgroundPayloadFilename = backgroundPayloadFilename
        self.pageSize = pageSize
        self.orientation = orientation
        self.lineColorHex = lineColorHex
        self.lineSpacingSteps = lineSpacingSteps
        self.isCover = isCover
        self.isBookmarked = isBookmarked
        self.bookmarkName = bookmarkName
    }

    /// The ink coordinate space for this page.
    public var logicalSize: CGSize { pageSize.size(orientation: orientation) }

    /// Everything about a page except its identity and content — what a new page
    /// inherits from its neighbour, and what "apply to all pages" copies.
    public var style: PageStyle {
        PageStyle(
            template: template, margin: margin, paperColorHex: paperColorHex,
            pageSize: pageSize, orientation: orientation,
            lineColorHex: lineColorHex, lineSpacingSteps: lineSpacingSteps
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, template, createdAt, elements, margin, paperColorHex
        case backgroundPayloadFilename, pageSize, orientation, lineColorHex, lineSpacingSteps
        case isCover, isBookmarked, bookmarkName
    }

    // Custom decode so older manifests (missing later keys) load without loss —
    // every added field defaults: elements empty, margin default, paper color and
    // background nil, and the page stays in the classic portrait geometry.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        template = try container.decode(PageTemplate.self, forKey: .template)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        elements = try container.decodeIfPresent([PageElement].self, forKey: .elements) ?? []
        margin = try container.decodeIfPresent(PageMargin.self, forKey: .margin) ?? .default
        paperColorHex = try container.decodeIfPresent(String.self, forKey: .paperColorHex)
        backgroundPayloadFilename = try container.decodeIfPresent(
            String.self, forKey: .backgroundPayloadFilename
        )
        pageSize = try container.decodeIfPresent(PageSize.self, forKey: .pageSize) ?? .classic
        orientation = try container.decodeIfPresent(
            PageOrientation.self, forKey: .orientation
        ) ?? .portrait
        lineColorHex = try container.decodeIfPresent(String.self, forKey: .lineColorHex)
        lineSpacingSteps = try container.decodeIfPresent(
            Int.self, forKey: .lineSpacingSteps
        ) ?? PageLineSpacing.default
        isCover = try container.decodeIfPresent(Bool.self, forKey: .isCover) ?? false
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        bookmarkName = try container.decodeIfPresent(String.self, forKey: .bookmarkName)
    }
}

/// The style half of a page: paper, geometry and rule appearance, with no id or
/// content. Passed around when creating pages so a new page always matches.
public struct PageStyle: Codable, Sendable, Equatable {
    public var template: PageTemplate
    public var margin: PageMargin
    public var paperColorHex: String?
    public var pageSize: PageSize
    public var orientation: PageOrientation
    public var lineColorHex: String?
    public var lineSpacingSteps: Int

    public init(
        template: PageTemplate = .ruled,
        margin: PageMargin = .default,
        paperColorHex: String? = nil,
        pageSize: PageSize = .classic,
        orientation: PageOrientation = .portrait,
        lineColorHex: String? = nil,
        lineSpacingSteps: Int = PageLineSpacing.default
    ) {
        self.template = template
        self.margin = margin
        self.paperColorHex = paperColorHex
        self.pageSize = pageSize
        self.orientation = orientation
        self.lineColorHex = lineColorHex
        self.lineSpacingSteps = lineSpacingSteps
    }

    public var logicalSize: CGSize { pageSize.size(orientation: orientation) }

    /// A fresh page in this style.
    public func makePage(backgroundPayloadFilename: String? = nil) -> PageRecord {
        PageRecord(
            template: template, margin: margin, paperColorHex: paperColorHex,
            backgroundPayloadFilename: backgroundPayloadFilename,
            pageSize: pageSize, orientation: orientation,
            lineColorHex: lineColorHex, lineSpacingSteps: lineSpacingSteps
        )
    }

    /// The notebook's cover as page one. It keeps the notebook's geometry so the
    /// page scroll stays even, and prints nothing under the ink — the cover
    /// artwork itself is the paper.
    public func makeCoverPage() -> PageRecord {
        PageRecord(
            template: .blank,
            margin: PageMargin(position: .none),
            pageSize: pageSize,
            orientation: orientation,
            isCover: true
        )
    }

    /// The default style for a plain quick note: white blank paper, no margin.
    public static let quickNote = PageStyle(
        template: .blank, margin: PageMargin(position: .none),
        paperColorHex: PaperPalette.white.color.hexString,
        pageSize: .a4, orientation: .portrait
    )

    /// The style an imported page (PDF / photo / scan) gets: nothing printed
    /// underneath the imported artwork.
    public static func imported(size: PageSize, orientation: PageOrientation) -> PageStyle {
        PageStyle(
            template: .blank, margin: PageMargin(position: .none),
            pageSize: size, orientation: orientation
        )
    }
}
