import Foundation
import SwiftData

/// Library metadata for one notebook. The ink itself lives in the document
/// package on disk keyed by `id` — see `DocumentStore`.
@Model
public final class Notebook {
    @Attribute(.unique) public var id: UUID
    public var title: String
    /// Cover color as a hex string from the theme's cover palette.
    public var coverColorHex: String
    public var defaultTemplateRaw: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        coverColorHex: String,
        defaultTemplate: PageTemplate = .ruled,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.coverColorHex = coverColorHex
        self.defaultTemplateRaw = defaultTemplate.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var defaultTemplate: PageTemplate {
        get { PageTemplate(rawValue: defaultTemplateRaw) ?? .ruled }
        set { defaultTemplateRaw = newValue.rawValue }
    }
}
