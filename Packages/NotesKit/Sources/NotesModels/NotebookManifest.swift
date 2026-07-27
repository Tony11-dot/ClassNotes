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
    /// notebook can be A4 landscape with blue rules. Older manifests decode fine —
    /// every added field is optional / defaulted.
    public static let currentVersion = 6

    public var version: Int
    public var pages: [PageRecord]

    public init(version: Int = NotebookManifest.currentVersion, pages: [PageRecord]) {
        self.version = version
        self.pages = pages
    }
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
        lineSpacingSteps: Int = PageLineSpacing.default
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
