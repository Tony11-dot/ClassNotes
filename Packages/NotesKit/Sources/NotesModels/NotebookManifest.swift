import Foundation

/// On-disk description of one notebook document package (`<uuid>.cmnote/`):
/// `manifest.json` (this type) plus `pages/<pageID>.drawing` blobs and the
/// `media/` payloads referenced by page elements. SwiftData never sees ink.
public struct NotebookManifest: Codable, Sendable, Equatable {
    /// v2 adds `PageRecord.elements` (images / voice notes / typeset text).
    /// v3 adds `PageRecord.margin`. v4 adds `PageRecord.paperColorHex` (a chosen
    /// page color). v5 adds `PageRecord.backgroundPayloadFilename` (an imported
    /// PDF page rendered as the page background, drawn on with all tools). Older
    /// manifests decode fine — every added field is optional / defaulted.
    public static let currentVersion = 5

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

    public init(
        id: UUID = UUID(),
        template: PageTemplate,
        createdAt: Date = .now,
        elements: [PageElement] = [],
        margin: PageMargin = .default,
        paperColorHex: String? = nil,
        backgroundPayloadFilename: String? = nil
    ) {
        self.id = id
        self.template = template
        self.createdAt = createdAt
        self.elements = elements
        self.margin = margin
        self.paperColorHex = paperColorHex
        self.backgroundPayloadFilename = backgroundPayloadFilename
    }

    private enum CodingKeys: String, CodingKey {
        case id, template, createdAt, elements, margin, paperColorHex, backgroundPayloadFilename
    }

    // Custom decode so older manifests (missing later keys) load without loss —
    // every added field defaults: elements empty, margin default, paper color and
    // background nil.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        template = try container.decode(PageTemplate.self, forKey: .template)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        elements = try container.decodeIfPresent([PageElement].self, forKey: .elements) ?? []
        margin = try container.decodeIfPresent(PageMargin.self, forKey: .margin) ?? .default
        paperColorHex = try container.decodeIfPresent(String.self, forKey: .paperColorHex)
        backgroundPayloadFilename = try container.decodeIfPresent(String.self, forKey: .backgroundPayloadFilename)
    }
}
