import Foundation

/// On-disk description of one notebook document package (`<uuid>.cmnote/`):
/// `manifest.json` (this type) plus `pages/<pageID>.drawing` blobs.
/// SwiftData never sees ink — it stores metadata only.
public struct NotebookManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

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

    public init(id: UUID = UUID(), template: PageTemplate, createdAt: Date = .now) {
        self.id = id
        self.template = template
        self.createdAt = createdAt
    }
}
