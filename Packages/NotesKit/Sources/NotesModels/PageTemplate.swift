import CoreGraphics
import Foundation

/// A page's printed background. Rule/grid/dot geometry is drawn by
/// `NotesDesignSystem.PageTemplateView` in the page's line color (falling back to
/// the theme's separator), at the page's chosen line spacing.
///
/// The first six are the originals and MUST keep their raw values — they're
/// persisted in every existing manifest.
public enum PageTemplate: String, CaseIterable, Sendable, Codable, Identifiable {
    // Basic
    case blank
    case ruled
    case dashed
    case dotted
    case grid
    case dotGrid
    // Study
    case cornell
    case todo
    case weekly
    // Creative / technical
    case music
    case isometric
    case storyboard
    case graph
    case log

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .blank: "Plain"
        case .ruled: "Rule"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        case .grid: "Grid"
        case .dotGrid: "Dot"
        case .cornell: "Cornell"
        case .todo: "Checklist"
        case .weekly: "Weekly"
        case .music: "Music"
        case .isometric: "Isometric"
        case .storyboard: "Storyboard"
        case .graph: "Graph"
        case .log: "Log"
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
        case .cornell: "rectangle.split.2x1"
        case .todo: "checklist"
        case .weekly: "calendar"
        case .music: "music.note.list"
        case .isometric: "cube"
        case .storyboard: "rectangle.grid.2x2"
        case .graph: "chart.xyaxis.line"
        case .log: "chart.bar.doc.horizontal"
        }
    }

    /// Groups used by the template pickers ("Basic Templates" and the rest).
    public enum Family: String, CaseIterable, Sendable, Identifiable {
        case basic
        case study
        case creative

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .basic: "Basic Templates"
            case .study: "Study Templates"
            case .creative: "Creative Templates"
            }
        }

        public var templates: [PageTemplate] {
            switch self {
            case .basic: [.blank, .ruled, .grid, .dotGrid, .dashed, .dotted]
            case .study: [.cornell, .todo, .weekly, .log]
            case .creative: [.music, .isometric, .storyboard, .graph]
            }
        }
    }

    public var family: Family {
        Family.allCases.first { $0.templates.contains(self) } ?? .basic
    }

    /// Templates that draw horizontal writing lines (ruled family) — used by the
    /// renderer to pick a stroke dash style.
    public var isRuledFamily: Bool {
        self == .ruled || self == .dashed || self == .dotted
    }

    /// Whether the line-spacing control does anything for this template.
    public var honorsLineSpacing: Bool {
        switch self {
        case .blank, .storyboard, .weekly, .cornell: false
        default: true
        }
    }
}

/// The per-page line-spacing control (the "Spacing" slider in New Notebook).
/// A step of 5 is the classic 32 pt rule; the scale keeps every template's
/// geometry proportional so a tight grid and tight rules agree.
public enum PageLineSpacing {
    public static let range = 1...9
    public static let `default` = 5
    /// Base geometry at step 5, in logical page points.
    public static let baseRuleSpacing: CGFloat = 32

    public static func scale(steps: Int) -> CGFloat {
        let clamped = min(max(steps, range.lowerBound), range.upperBound)
        // step 1 → 0.68×, step 5 → 1.0×, step 9 → 1.32×
        return 0.6 + CGFloat(clamped) * 0.08
    }
}
