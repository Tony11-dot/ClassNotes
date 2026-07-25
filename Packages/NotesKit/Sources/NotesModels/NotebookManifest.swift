import Foundation

/// On-disk description of one notebook document package (`<uuid>.cmnote/`):
/// `manifest.json` (this type) plus `pages/<pageID>.drawing` blobs and the
/// `media/` payloads referenced by page elements. SwiftData never sees ink.
public struct NotebookManifest: Codable, Sendable, Equatable {
    /// v2 adds `PageRecord.elements` (images / voice notes / typeset text).
    /// v3 adds `PageRecord.margin`. Older manifests decode fine — `elements`
    /// defaults to empty and `margin` to the default leading line.
    public static let currentVersion = 3

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

    public init(
        id: UUID = UUID(),
        template: PageTemplate,
        createdAt: Date = .now,
        elements: [PageElement] = [],
        margin: PageMargin = .default
    ) {
        self.id = id
        self.template = template
        self.createdAt = createdAt
        self.elements = elements
        self.margin = margin
    }

    private enum CodingKeys: String, CodingKey {
        case id, template, createdAt, elements, margin
    }

    // Custom decode so v1/v2 manifests (no `elements`/`margin` keys) load
    // without loss — missing elements default to empty, missing margin to the
    // default leading line.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        template = try container.decode(PageTemplate.self, forKey: .template)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        elements = try container.decodeIfPresent([PageElement].self, forKey: .elements) ?? []
        margin = try container.decodeIfPresent(PageMargin.self, forKey: .margin) ?? .default
    }
}
