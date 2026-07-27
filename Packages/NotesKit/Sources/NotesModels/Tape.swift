import CoreGraphics
import Foundation

/// How a strip of sticky tape was laid down.
public enum TapeShape: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Freeform — the strip follows the pencil.
    case draw
    /// A straight strip between the two ends of the drag.
    case line
    /// A filled rectangle covering the dragged area.
    case rectangle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .draw: "Draw"
        case .line: "Straight Line"
        case .rectangle: "Rectangle"
        }
    }

    public var symbolName: String {
        switch self {
        case .draw: "scribble.variable"
        case .line: "line.diagonal"
        case .rectangle: "rectangle.dashed"
        }
    }
}

/// The printed pattern on a strip of tape. Every pattern is drawn procedurally
/// from the strip's own color, so tape follows the theme and ships no assets.
public enum TapePattern: String, CaseIterable, Sendable, Codable, Identifiable {
    case solid
    case stripes
    case checker
    case dots
    case grid
    case hearts
    case stars
    case waves
    case confetti
    case gradient

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .solid: "Solid"
        case .stripes: "Stripes"
        case .checker: "Checks"
        case .dots: "Dots"
        case .grid: "Grid"
        case .hearts: "Hearts"
        case .stars: "Stars"
        case .waves: "Waves"
        case .confetti: "Confetti"
        case .gradient: "Fade"
        }
    }

    /// Patterns whose motif is a repeated glyph rather than a stroke/fill.
    public var isGlyphPattern: Bool {
        switch self {
        case .hearts, .stars, .confetti: true
        default: false
        }
    }
}

/// Geometry rules shared by the tape tool and the tape renderer, kept pure so
/// they're testable without a canvas.
public enum TapeGeometry {
    public static let minThickness: Double = 8
    public static let maxThickness: Double = 90
    public static let defaultThickness: Double = 30

    /// The element frame that encloses a tape path drawn with `thickness`,
    /// clamped to the page. Freeform/line tape stores its path in page space and
    /// the frame is just its padded bounding box; rectangle tape has no path.
    public static func frame(
        for points: [CGPoint], thickness: Double, in pageSize: CGSize
    ) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let pad = thickness / 2 + 2
        let rect = CGRect(
            x: minX - pad, y: minY - pad,
            width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2
        )
        return rect.intersection(CGRect(origin: .zero, size: pageSize))
    }

    /// Resamples a drag into a tidy path: the two ends for `line`, the raw path
    /// (thinned) for `draw`, and nothing for `rectangle`.
    public static func path(for shape: TapeShape, from points: [CGPoint]) -> [CGPoint] {
        switch shape {
        case .rectangle:
            return []
        case .line:
            guard let first = points.first, let last = points.last else { return [] }
            return [first, last]
        case .draw:
            return thin(points, minimumSpacing: 3)
        }
    }

    /// Drops points closer together than `minimumSpacing` so a long freeform
    /// strip doesn't bloat the manifest.
    public static func thin(_ points: [CGPoint], minimumSpacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst() {
            let previous = result[result.count - 1]
            if hypot(point.x - previous.x, point.y - previous.y) >= minimumSpacing {
                result.append(point)
            }
        }
        if let last = points.last, result.count > 1, result[result.count - 1] != last {
            result.append(last)
        }
        return result
    }
}
