import ClassMateTheme
import NotesModels
import Observation
import PencilKit
import UIKit

/// The editor's tool selection + per-tool options, mapped to PencilKit tools.
/// Default ink colors come from the active theme; the swatch palette is the
/// theme's ink, accent and cover colors.
@MainActor
@Observable
public final class ToolState {
    /// Canvas-affecting modes. Rail actions (ruler, insert, record, page
    /// settings, page manager) are NOT tools — they live alongside these.
    public enum Tool: String, CaseIterable, Sendable, Identifiable {
        case pen
        case marker
        case eraser
        case hand

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .pen: "Pen"
            case .marker: "Marker"
            case .eraser: "Eraser"
            case .hand: "Hand"
            }
        }

        public var symbolName: String {
            switch self {
            case .pen: "pencil.tip"
            case .marker: "highlighter"
            case .eraser: "eraser"
            case .hand: "hand.point.up.left"
            }
        }

        /// The pen/marker tools carry ink options; eraser has its own; hand has
        /// none (it moves objects, the pencil doesn't draw).
        public var hasInkOptions: Bool { self == .pen || self == .marker }
    }

    /// Pen stroke character — maps to PencilKit ink types.
    public enum PenInk: String, CaseIterable, Sendable, Identifiable {
        case pen
        case pencil
        case fountain
        case monoline

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .pen: "Pen"
            case .pencil: "Pencil"
            case .fountain: "Fountain"
            case .monoline: "Monoline"
            }
        }

        public var pkInkType: PKInk.InkType {
            switch self {
            case .pen: .pen
            case .pencil: .pencil
            case .fountain: .fountainPen
            case .monoline: .monoline
            }
        }
    }

    /// Eraser precision: pixel (accurate, adjustable size) or whole-stroke.
    public enum EraserMode: String, CaseIterable, Sendable, Identifiable {
        case pixel
        case stroke

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .pixel: "Pixel"
            case .stroke: "Whole stroke"
            }
        }
    }

    public var tool: Tool = .pen
    /// Last pen/marker tool, for Pencil double-tap toggling.
    public private(set) var previousDrawingTool: Tool = .pen

    // Pen
    /// `nil` = follow the theme's ink color.
    public var penColorHex: String?
    public var penWidth: Double = 3
    public var penInk: PenInk = .pen
    /// Handwriting beautification: when on, "Beautify" re-typesets the page's
    /// handwriting into `beautifyFontID` (a real text element, not a textbox).
    public var beautifyEnabled: Bool = false
    public var beautifyFontID: String = FontLibrary.default.id

    // Marker
    public var markerColorHex: String?
    public var markerWidth: Double = 14
    public var markerOpacity: Double = 0.4

    // Eraser
    public var eraserMode: EraserMode = .pixel
    public var eraserWidth: Double = 20

    public init() {}

    /// The pen draws unless we're in hand (object) mode.
    public var isDrawingEnabled: Bool { tool != .hand }

    public var beautifyFont: HandwritingFont { FontLibrary.font(id: beautifyFontID) }

    public func select(_ newTool: Tool) {
        if tool == .pen || tool == .marker {
            previousDrawingTool = tool
        }
        tool = newTool
    }

    /// Apple Pencil double-tap: honor the system preference where it maps to
    /// tool switching; anything else falls back to eraser toggle.
    public func handlePencilTap(preferred: UIPencilPreferredAction) {
        switch preferred {
        case .switchPrevious:
            let target = previousDrawingTool
            if tool == .pen || tool == .marker { previousDrawingTool = tool }
            tool = target
        default:
            toggleEraser()
        }
    }

    /// Apple Pencil squeeze: cycle pen → marker → eraser → hand.
    public func handlePencilSqueeze() {
        let order: [Tool] = [.pen, .marker, .eraser, .hand]
        guard let index = order.firstIndex(of: tool) else {
            select(.pen)
            return
        }
        select(order[(index + 1) % order.count])
    }

    private func toggleEraser() {
        if tool == .eraser {
            tool = previousDrawingTool
        } else {
            select(.eraser)
        }
    }

    // MARK: - Colors / widths for the active tool

    public func inkPalette(theme: ThemeSpec) -> [ThemeColor] {
        var seen = Set<String>()
        var palette: [ThemeColor] = []
        for candidate in [theme.ink, theme.accent] + theme.coverPalette {
            if seen.insert(candidate.hexString).inserted {
                palette.append(candidate)
            }
            if palette.count == 10 { break }
        }
        return palette
    }

    public func currentColor(theme: ThemeSpec) -> ThemeColor {
        let hex = tool == .marker ? markerColorHex : penColorHex
        let fallback = tool == .marker ? theme.accent : theme.ink
        return hex.flatMap(ThemeColor.init(hex:)) ?? fallback
    }

    public func setCurrentColor(_ color: ThemeColor) {
        if tool == .marker {
            markerColorHex = color.hexString
        } else {
            penColorHex = color.hexString
        }
    }

    public var currentWidth: Double {
        get { tool == .marker ? markerWidth : penWidth }
        set {
            if tool == .marker {
                markerWidth = newValue
            } else {
                penWidth = newValue
            }
        }
    }

    // MARK: - PencilKit mapping

    public func pkTool(theme: ThemeSpec) -> PKTool {
        switch tool {
        case .pen:
            let color = penColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink
            return PKInkingTool(penInk.pkInkType, color: color.uiColor, width: penWidth)
        case .marker:
            let base = (markerColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accent).uiColor
            let color = base.withAlphaComponent(markerOpacity)
            return PKInkingTool(.marker, color: color, width: markerWidth)
        case .eraser:
            switch eraserMode {
            case .pixel: return PKEraserTool(.bitmap, width: eraserWidth)
            case .stroke: return PKEraserTool(.vector)
            }
        case .hand:
            // Inert — drawing is disabled in hand mode; the value is unused.
            return PKInkingTool(.pen, color: .clear, width: 1)
        }
    }
}

extension ThemeColor {
    /// UIKit bridge for PencilKit tools.
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
