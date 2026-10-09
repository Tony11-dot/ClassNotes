import Foundation

/// Pages deleted from a notebook, kept inside its package (`trash.json`) so a
/// delete can be undone — straight away from the Undo toast, or later — until
/// `TrashPolicy.retention` runs out.
///
/// Deleting a page used to remove its ink blob and every photo, scan and voice
/// note it held the moment the finger lifted. A long-press menu is an easy
/// place to mis-tap, and a multi-select delete takes a dozen pages at once.
/// Lives beside the manifest rather than in it, so the manifest's format does
/// not change and an older build simply ignores it.
public struct PageTrash: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        /// The page exactly as it was, elements and all.
        public var page: PageRecord
        /// Where it sat when it was deleted, so a restore puts it back there.
        public var index: Int
        public var deletedAt: Date

        public var id: UUID { page.id }

        public init(page: PageRecord, index: Int, deletedAt: Date) {
            self.page = page
            self.index = index
            self.deletedAt = deletedAt
        }
    }

    public var version: Int
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.version = Self.currentVersion
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    /// Total: a damaged entry is dropped, never the whole trash.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        entries = (try? container.decode(LossyArray<Entry>.self, forKey: .entries))?.elements ?? []
    }
}

/// A notebook's library metadata, written INTO its package (`info.json`).
///
/// The library lists notebooks from SwiftData rows, and the ink lives in
/// packages on disk. A package with no row was simply invisible. That happened
/// after a crash between writing the package and saving the row, and whenever
/// the metadata store couldn't be opened: the app then ran on an empty
/// in-memory library while every notebook sat untouched on disk. With its own
/// description inside, a package can always be put back in the library under
/// its real name, cover and shelf.
///
/// Derived from the row and rewritten whenever the row changes. The row stays
/// the source of truth while it exists; this is what it is rebuilt from when it
/// doesn't.
public struct NotebookInfo: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var title: String
    public var kind: String
    public var coverColorHex: String
    public var coverDesign: String
    public var showsCover: Bool
    public var defaultTemplate: String
    public var pageSize: String
    public var orientation: String
    public var paperColorHex: String?
    public var lineColorHex: String?
    public var lineSpacingSteps: Int
    public var shelfID: UUID?
    /// The shelf's own description, so a library rebuilt from packages alone can
    /// put the shelf back too, not just a dangling id.
    public var shelfName: String?
    public var shelfColorHex: String?
    public var shelfSymbol: String?
    public var isFavorite: Bool
    public var isViewOnly: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    /// Absent in descriptions written before tags existed.
    public var tags: [String]?
    /// `Notebook.metadataRevisedAt`; absent before iCloud sync.
    public var revisedAt: Date?

    public init(
        id: UUID, title: String, kind: String, coverColorHex: String, coverDesign: String,
        showsCover: Bool, defaultTemplate: String, pageSize: String, orientation: String,
        paperColorHex: String?, lineColorHex: String?, lineSpacingSteps: Int,
        shelfID: UUID?, shelfName: String?, shelfColorHex: String?, shelfSymbol: String?,
        isFavorite: Bool, isViewOnly: Bool, createdAt: Date, updatedAt: Date, deletedAt: Date?,
        tags: [String]? = nil,
        revisedAt: Date? = nil
    ) {
        self.version = Self.currentVersion
        self.id = id
        self.title = title
        self.kind = kind
        self.coverColorHex = coverColorHex
        self.coverDesign = coverDesign
        self.showsCover = showsCover
        self.defaultTemplate = defaultTemplate
        self.pageSize = pageSize
        self.orientation = orientation
        self.paperColorHex = paperColorHex
        self.lineColorHex = lineColorHex
        self.lineSpacingSteps = lineSpacingSteps
        self.shelfID = shelfID
        self.shelfName = shelfName
        self.shelfColorHex = shelfColorHex
        self.shelfSymbol = shelfSymbol
        self.isFavorite = isFavorite
        self.isViewOnly = isViewOnly
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.tags = tags
        self.revisedAt = revisedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, title, kind, coverColorHex, coverDesign, showsCover
        case defaultTemplate, pageSize, orientation, paperColorHex, lineColorHex
        case lineSpacingSteps, shelfID, shelfName, shelfColorHex, shelfSymbol
        case isFavorite, isViewOnly, createdAt, updatedAt, deletedAt, tags, revisedAt
    }

    /// Total apart from the id: this file exists to recover a notebook, so a
    /// field it can't read falls back rather than costing the whole record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        version = (try? c.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        title = (try? c.decode(String.self, forKey: .title)) ?? "Recovered notebook"
        kind = (try? c.decode(String.self, forKey: .kind)) ?? NotebookKind.notebook.rawValue
        coverColorHex = (try? c.decode(String.self, forKey: .coverColorHex)) ?? ""
        coverDesign = (try? c.decode(String.self, forKey: .coverDesign)) ?? CoverDesign.default.rawValue
        showsCover = (try? c.decode(Bool.self, forKey: .showsCover)) ?? true
        defaultTemplate = (try? c.decode(String.self, forKey: .defaultTemplate)) ?? PageTemplate.ruled.rawValue
        pageSize = (try? c.decode(String.self, forKey: .pageSize)) ?? PageSize.classic.rawValue
        orientation = (try? c.decode(String.self, forKey: .orientation)) ?? PageOrientation.portrait.rawValue
        paperColorHex = try? c.decodeIfPresent(String.self, forKey: .paperColorHex)
        lineColorHex = try? c.decodeIfPresent(String.self, forKey: .lineColorHex)
        lineSpacingSteps = (try? c.decode(Int.self, forKey: .lineSpacingSteps)) ?? PageLineSpacing.default
        shelfID = try? c.decodeIfPresent(UUID.self, forKey: .shelfID)
        shelfName = try? c.decodeIfPresent(String.self, forKey: .shelfName)
        shelfColorHex = try? c.decodeIfPresent(String.self, forKey: .shelfColorHex)
        shelfSymbol = try? c.decodeIfPresent(String.self, forKey: .shelfSymbol)
        isFavorite = (try? c.decode(Bool.self, forKey: .isFavorite)) ?? false
        isViewOnly = (try? c.decode(Bool.self, forKey: .isViewOnly)) ?? false
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .now
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        deletedAt = try? c.decodeIfPresent(Date.self, forKey: .deletedAt)
        tags = try? c.decodeIfPresent([String].self, forKey: .tags)
        revisedAt = try? c.decodeIfPresent(Date.self, forKey: .revisedAt)
    }
}

public extension Notebook {
    /// This row as the package describes it. `shelf` is the row's shelf, looked
    /// up by the caller, so its name travels with the notebook.
    func info(shelf: Shelf?) -> NotebookInfo {
        NotebookInfo(
            id: id, title: title, kind: kindRaw, coverColorHex: coverColorHex,
            coverDesign: coverDesignRaw, showsCover: showsCover,
            defaultTemplate: defaultTemplateRaw, pageSize: pageSizeRaw,
            orientation: orientationRaw, paperColorHex: paperColorHex,
            lineColorHex: lineColorHex, lineSpacingSteps: lineSpacingSteps,
            shelfID: shelfID, shelfName: shelf?.name, shelfColorHex: shelf?.colorHex,
            shelfSymbol: shelf?.symbolName, isFavorite: isFavorite, isViewOnly: isViewOnly,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt,
            tags: tags.isEmpty ? nil : tags,
            revisedAt: metadataRevisedAt
        )
    }

    /// A row rebuilt from a package's own description.
    convenience init(info: NotebookInfo) {
        self.init(
            id: info.id,
            title: info.title,
            coverColorHex: info.coverColorHex,
            defaultTemplate: PageTemplate(rawValue: info.defaultTemplate) ?? .ruled,
            shelfID: info.shelfID,
            createdAt: info.createdAt,
            kind: NotebookKind(rawValue: info.kind) ?? .notebook,
            coverDesign: CoverDesign(rawValue: info.coverDesign) ?? .default,
            showsCover: info.showsCover,
            pageSize: PageSize(rawValue: info.pageSize) ?? .classic,
            orientation: PageOrientation(rawValue: info.orientation) ?? .portrait,
            paperColorHex: info.paperColorHex,
            lineColorHex: info.lineColorHex,
            lineSpacingSteps: info.lineSpacingSteps
        )
        updatedAt = info.updatedAt
        isFavorite = info.isFavorite
        isViewOnly = info.isViewOnly
        deletedAt = info.deletedAt
        tags = info.tags ?? []
        metadataRevisedAt = info.revisedAt ?? info.updatedAt
    }
}
