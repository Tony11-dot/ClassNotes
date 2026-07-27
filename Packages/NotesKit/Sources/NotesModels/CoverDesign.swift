import Foundation

/// A notebook cover artwork. Every design is drawn procedurally by
/// `NotesDesignSystem.NotebookCoverView` from the notebook's chosen cover color,
/// so covers ship no assets, stay crisp at any size, and follow the theme.
///
/// Ordered simple → decorated, which is also the order the cover picker shows.
public enum CoverDesign: String, CaseIterable, Sendable, Codable, Identifiable {
    // Simple — flat stocks with a spine, the "real notebook" look.
    case simple1
    case simple2
    case simple3
    case simple4
    // Classic stationery
    case composition
    case ledger
    case labelled
    case index
    // Patterns
    case stripes
    case pinstripe
    case checks
    case dots
    case gridlines
    case diamonds
    case arches
    case waves
    // Gradients / light
    case dusk
    case sunrise
    case aurora
    case halo
    // Textures
    case linen
    case kraft
    case marble
    case carbon
    // Playful
    case confetti
    case bloom
    case stars
    case terrazzo

    public var id: String { rawValue }

    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case simple
        case classic
        case pattern
        case gradient
        case texture
        case playful

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .simple: "Simple"
            case .classic: "Classic"
            case .pattern: "Patterns"
            case .gradient: "Light"
            case .texture: "Textures"
            case .playful: "Playful"
            }
        }

        public var designs: [CoverDesign] {
            switch self {
            case .simple: [.simple1, .simple2, .simple3, .simple4]
            case .classic: [.composition, .ledger, .labelled, .index]
            case .pattern: [.stripes, .pinstripe, .checks, .dots, .gridlines, .diamonds, .arches, .waves]
            case .gradient: [.dusk, .sunrise, .aurora, .halo]
            case .texture: [.linen, .kraft, .marble, .carbon]
            case .playful: [.confetti, .bloom, .stars, .terrazzo]
            }
        }
    }

    public var category: Category {
        Category.allCases.first { $0.designs.contains(self) } ?? .simple
    }

    public var displayName: String {
        switch self {
        case .simple1: "Simple 1"
        case .simple2: "Simple 2"
        case .simple3: "Simple 3"
        case .simple4: "Simple 4"
        case .composition: "Composition"
        case .ledger: "Ledger"
        case .labelled: "Label"
        case .index: "Index"
        case .stripes: "Stripes"
        case .pinstripe: "Pinstripe"
        case .checks: "Checks"
        case .dots: "Dots"
        case .gridlines: "Grid"
        case .diamonds: "Diamonds"
        case .arches: "Arches"
        case .waves: "Waves"
        case .dusk: "Dusk"
        case .sunrise: "Sunrise"
        case .aurora: "Aurora"
        case .halo: "Halo"
        case .linen: "Linen"
        case .kraft: "Kraft"
        case .marble: "Marble"
        case .carbon: "Carbon"
        case .confetti: "Confetti"
        case .bloom: "Bloom"
        case .stars: "Stars"
        case .terrazzo: "Terrazzo"
        }
    }

    /// The design a brand-new notebook (and a quick note) gets.
    public static var `default`: CoverDesign { .simple1 }

    /// Designs whose artwork already carries a title band, so the cover view
    /// places the title inside it instead of at the bottom-left.
    public var hasTitlePlate: Bool {
        switch self {
        case .composition, .labelled, .index, .ledger: true
        default: false
        }
    }
}

/// What kind of document a library entry is. All of them are notebook packages on
/// disk; the kind decides how the editor presents them.
public enum NotebookKind: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Paged notebook — the default.
    case notebook
    /// One big board with pan + zoom and no page breaks.
    case whiteboard
    /// A photo (or several) turned into annotatable pages.
    case image
    /// An imported PDF / file turned into annotatable pages.
    case document
    /// A scan from the camera turned into annotatable pages.
    case scan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notebook: "Notebook"
        case .whiteboard: "Whiteboard"
        case .image: "Image"
        case .document: "Document"
        case .scan: "Scan"
        }
    }

    public var symbolName: String {
        switch self {
        case .notebook: "book.closed"
        case .whiteboard: "rectangle.on.rectangle"
        case .image: "photo"
        case .document: "folder"
        case .scan: "doc.viewfinder"
        }
    }

    /// A board is one page you pan and zoom; everything else scrolls page by page.
    public var isSinglePage: Bool { self == .whiteboard }
}
