import ClassMateTheme
import Observation
import PencilKit
import UIKit

/// The editor's tool selection + per-tool options, mapped to PencilKit tools.
/// Default ink colors come from the active theme; the swatch palette is the
/// theme's ink, accent and cover colors.
@MainActor
@Observable
public final class ToolState {
    public enum Tool: String, CaseIterable, Sendable, Identifiable {
        case pen
        case highlighter
        case eraser
        case lasso

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .pen: "Pen"
            case .highlighter: "Highlighter"
            case .eraser: "Eraser"
            case .lasso: "Lasso"
            }
        }

        public var symbolName: String {
            switch self {
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .eraser: "eraser"
            case .lasso: "lasso"
            }
        }
    }

    public var tool: Tool = .pen
    /// Last non-eraser tool, for Pencil double-tap toggling.
    public private(set) var previousDrawingTool: Tool = .pen

    /// `nil` = follow the theme's ink color.
    public var penColorHex: String?
    public var penWidth: Double = 3
    public var highlighterColorHex: String?
    public var highlighterWidth: Double = 14

    public init() {}

    public func select(_ newTool: Tool) {
        if tool == .pen || tool == .highlighter {
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
            if tool == .pen || tool == .highlighter { previousDrawingTool = tool }
            tool = target
        default:
            toggleEraser()
        }
    }

    /// Apple Pencil squeeze: cycle pen → highlighter → eraser → lasso.
    public func handlePencilSqueeze() {
        let order: [Tool] = [.pen, .highlighter, .eraser, .lasso]
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

    // MARK: - PencilKit mapping

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
        let hex = tool == .highlighter ? highlighterColorHex : penColorHex
        let fallback = tool == .highlighter ? theme.accent : theme.ink
        return hex.flatMap(ThemeColor.init(hex:)) ?? fallback
    }

    public func setCurrentColor(_ color: ThemeColor) {
        if tool == .highlighter {
            highlighterColorHex = color.hexString
        } else {
            penColorHex = color.hexString
        }
    }

    public var currentWidth: Double {
        get { tool == .highlighter ? highlighterWidth : penWidth }
        set {
            if tool == .highlighter {
                highlighterWidth = newValue
            } else {
                penWidth = newValue
            }
        }
    }

    public func pkTool(theme: ThemeSpec) -> PKTool {
        switch tool {
        case .pen:
            let color = penColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink
            return PKInkingTool(.pen, color: color.uiColor, width: penWidth)
        case .highlighter:
            let color = highlighterColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accent
            return PKInkingTool(.marker, color: color.uiColor, width: highlighterWidth)
        case .eraser:
            return PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        }
    }
}

extension ThemeColor {
    /// UIKit bridge for PencilKit tools.
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
