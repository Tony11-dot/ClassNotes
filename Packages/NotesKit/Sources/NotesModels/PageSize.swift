import CoreGraphics
import Foundation

/// The paper size a page (and by default, a whole notebook) is cut to.
///
/// Values are real typographic points (72 pt = 1 inch), which is also the ink
/// coordinate space: a stroke saved on an A4 page lives in 595×842, and every
/// renderer scales that space to fit the screen. `classic` is the original
/// ClassNotes page — pages written before sizes existed decode as `classic`, so
/// their ink keeps its exact geometry forever.
public enum PageSize: String, CaseIterable, Sendable, Codable, Identifiable {
    /// 768×1024 — the Milestone-1 ClassNotes page. Never change these numbers.
    case classic
    case a4
    case a5
    case b5
    case letter
    case legal
    case tabloid
    /// 1:1, for sketching and mind maps.
    case square
    /// 16:9, for slide-style notes.
    case widescreen
    /// A big scrollable board — used by whiteboard documents, which have exactly
    /// one page and pan/zoom instead of paging.
    case whiteboard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: "Classic"
        case .a4: "A4"
        case .a5: "A5"
        case .b5: "B5"
        case .letter: "Letter"
        case .legal: "Legal"
        case .tabloid: "Tabloid"
        case .square: "Square"
        case .widescreen: "Widescreen"
        case .whiteboard: "Board"
        }
    }

    /// Portrait dimensions in logical page points.
    public var portraitSize: CGSize {
        switch self {
        case .classic: CGSize(width: 768, height: 1024)
        case .a4: CGSize(width: 595, height: 842)
        case .a5: CGSize(width: 420, height: 595)
        case .b5: CGSize(width: 499, height: 709)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        case .tabloid: CGSize(width: 792, height: 1224)
        case .square: CGSize(width: 768, height: 768)
        case .widescreen: CGSize(width: 576, height: 1024)
        case .whiteboard: CGSize(width: 1600, height: 2400)
        }
    }

    /// The sizes offered when creating a paged notebook (a board isn't a choice
    /// there — it's a different document kind).
    public static var notebookChoices: [PageSize] {
        [.a4, .letter, .classic, .a5, .b5, .legal, .tabloid, .square, .widescreen]
    }

    public func size(orientation: PageOrientation) -> CGSize {
        orientation == .portrait
            ? portraitSize
            : CGSize(width: portraitSize.height, height: portraitSize.width)
    }
}

/// Which way round the page is cut. "Direction" in the New Notebook sheet.
public enum PageOrientation: String, CaseIterable, Sendable, Codable, Identifiable {
    case portrait
    case landscape

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .portrait: "Vertical"
        case .landscape: "Horizontal"
        }
    }

    public var symbolName: String {
        switch self {
        case .portrait: "rectangle.portrait"
        case .landscape: "rectangle"
        }
    }
}

/// The default logical page space, kept for code (and old documents) that predate
/// per-page sizes. New work should read `PageRecord.logicalSize`.
public enum PageGeometry {
    public static let size = PageSize.classic.portraitSize

    /// Convenience so callers don't have to spell out the two-step lookup.
    public static func size(_ pageSize: PageSize, _ orientation: PageOrientation) -> CGSize {
        pageSize.size(orientation: orientation)
    }
}
