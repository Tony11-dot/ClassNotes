import Foundation
import SwiftData

/// Library metadata for one notebook. The ink itself lives in the document
/// package on disk keyed by `id` — see `DocumentStore`.
///
/// Every property added after Milestone 1 has a default, so SwiftData's
/// lightweight migration adopts existing rows: an old notebook becomes a paged
/// `.notebook` with the `simple1` cover in the classic page geometry.
@Model
public final class Notebook {
    @Attribute(.unique) public var id: UUID
    public var title: String
    /// Cover color as a hex string from the theme's cover palette.
    public var coverColorHex: String
    public var defaultTemplateRaw: String
    /// Optional shelf/bag this notebook belongs to (`nil` = unfiled).
    public var shelfID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    // MARK: Added in Milestone 2

    /// `NotebookKind.rawValue` — paged notebook, board, image, document or scan.
    public var kindRaw: String = NotebookKind.notebook.rawValue
    /// `CoverDesign.rawValue` — the cover artwork.
    public var coverDesignRaw: String = CoverDesign.default.rawValue
    /// The "Cover" switch in New Notebook: off means the library shows the first
    /// page instead of a cover, and opening goes straight to page one.
    public var showsCover: Bool = true
    /// The notebook's page geometry — new pages inherit it.
    public var pageSizeRaw: String = PageSize.classic.rawValue
    public var orientationRaw: String = PageOrientation.portrait.rawValue
    /// Default paper and rule colors for new pages (`nil` = auto/theme).
    public var paperColorHex: String?
    public var lineColorHex: String?
    public var lineSpacingSteps: Int = PageLineSpacing.default

    public init(
        id: UUID = UUID(),
        title: String,
        coverColorHex: String,
        defaultTemplate: PageTemplate = .ruled,
        shelfID: UUID? = nil,
        createdAt: Date = .now,
        kind: NotebookKind = .notebook,
        coverDesign: CoverDesign = .default,
        showsCover: Bool = true,
        pageSize: PageSize = .classic,
        orientation: PageOrientation = .portrait,
        paperColorHex: String? = nil,
        lineColorHex: String? = nil,
        lineSpacingSteps: Int = PageLineSpacing.default
    ) {
        self.id = id
        self.title = title
        self.coverColorHex = coverColorHex
        self.defaultTemplateRaw = defaultTemplate.rawValue
        self.shelfID = shelfID
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.kindRaw = kind.rawValue
        self.coverDesignRaw = coverDesign.rawValue
        self.showsCover = showsCover
        self.pageSizeRaw = pageSize.rawValue
        self.orientationRaw = orientation.rawValue
        self.paperColorHex = paperColorHex
        self.lineColorHex = lineColorHex
        self.lineSpacingSteps = lineSpacingSteps
    }

    public var defaultTemplate: PageTemplate {
        get { PageTemplate(rawValue: defaultTemplateRaw) ?? .ruled }
        set { defaultTemplateRaw = newValue.rawValue }
    }

    public var kind: NotebookKind {
        get { NotebookKind(rawValue: kindRaw) ?? .notebook }
        set { kindRaw = newValue.rawValue }
    }

    public var coverDesign: CoverDesign {
        get { CoverDesign(rawValue: coverDesignRaw) ?? .default }
        set { coverDesignRaw = newValue.rawValue }
    }

    public var pageSize: PageSize {
        get { PageSize(rawValue: pageSizeRaw) ?? .classic }
        set { pageSizeRaw = newValue.rawValue }
    }

    public var orientation: PageOrientation {
        get { PageOrientation(rawValue: orientationRaw) ?? .portrait }
        set { orientationRaw = newValue.rawValue }
    }

    /// The page style new pages in this notebook are cut to.
    public var pageStyle: PageStyle {
        PageStyle(
            template: defaultTemplate,
            margin: .default,
            paperColorHex: paperColorHex,
            pageSize: pageSize,
            orientation: orientation,
            lineColorHex: lineColorHex,
            lineSpacingSteps: lineSpacingSteps
        )
    }
}
