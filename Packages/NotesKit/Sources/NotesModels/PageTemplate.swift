import CoreGraphics
import Foundation

/// The four Milestone-1 page backgrounds. Rule/grid lines are drawn by
/// `NotesDesignSystem.PageTemplateView` in the active theme's separator color.
public enum PageTemplate: String, CaseIterable, Sendable, Codable, Identifiable {
    case blank
    case ruled
    case dashed
    case dotted
    case grid
    case dotGrid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .blank: "Blank"
        case .ruled: "Ruled"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        case .grid: "Grid"
        case .dotGrid: "Dot grid"
        }
    }

    public var symbolName: String {
        switch self {
        case .blank: "rectangle.portrait"
        case .ruled: "text.justify"
        case .dashed: "line.3.horizontal.decrease"
        case .dotted: "ellipsis"
        case .grid: "grid"
        case .dotGrid: "circle.grid.3x3"
        }
    }

    /// Templates that draw horizontal writing lines (ruled family) — used by the
    /// renderer to pick a stroke dash style.
    public var isRuledFamily: Bool {
        self == .ruled || self == .dashed || self == .dotted
    }
}

/// One logical page size for every notebook (4:3 portrait, iPad-native).
/// Stored ink coordinates are in this space; viewers scale to fit.
public enum PageGeometry {
    public static let size = CGSize(width: 768, height: 1024)
}
