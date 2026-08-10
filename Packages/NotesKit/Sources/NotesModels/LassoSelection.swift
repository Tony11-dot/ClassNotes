import CoreGraphics
import Foundation

/// Working out what a circled region actually caught.
///
/// Pure geometry so the rules — how much of a stroke has to be inside before it
/// counts, what a barely-closed loop means — are pinned by tests rather than
/// discovered by circling things and seeing what disappears.
public enum LassoSelection {
    /// How much of a stroke's length must fall inside the loop for it to be
    /// selected. Well under half, because people circle generously and clip the
    /// ends of what they meant; well above nothing, so a loop drawn beside a word
    /// doesn't drag in the letter it grazed.
    public static let coverage = 0.4

    /// True when `point` is inside the closed polygon `loop` (even-odd rule).
    public static func contains(_ loop: [CGPoint], _ point: CGPoint) -> Bool {
        guard loop.count > 2 else { return false }
        var inside = false
        var previous = loop.count - 1
        for current in loop.indices {
            let a = loop[current], b = loop[previous]
            if (a.y > point.y) != (b.y > point.y) {
                let x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    /// The fraction of `points` that lie inside the loop.
    public static func fractionInside(_ loop: [CGPoint], of points: [CGPoint]) -> Double {
        guard !points.isEmpty else { return 0 }
        let hits = points.reduce(into: 0) { total, point in
            if contains(loop, point) { total += 1 }
        }
        return Double(hits) / Double(points.count)
    }

    /// Whether a circled loop caught the thing sampled as `points`.
    public static func catches(_ loop: [CGPoint], _ points: [CGPoint]) -> Bool {
        fractionInside(loop, of: points) >= coverage
    }

    /// Whether a rectangle (an element's frame) was caught: its centre inside, or
    /// most of its corners. An image is a big object and a loop around it rarely
    /// clears all four corners.
    public static func catches(_ loop: [CGPoint], frame: CGRect) -> Bool {
        guard !frame.isNull, !frame.isEmpty else { return false }
        if contains(loop, CGPoint(x: frame.midX, y: frame.midY)) { return true }
        let corners = [
            CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)
        ]
        return corners.filter { contains(loop, $0) }.count >= 3
    }

    /// A loop closed off, so a lasso the user didn't quite finish still encloses
    /// what they drew it around. Returns nil for a scribble too small to be a
    /// deliberate circle.
    public static func closed(_ points: [CGPoint], minimumSpan: CGFloat = 24) -> [CGPoint]? {
        guard points.count >= 3 else { return nil }
        let box = points.dropFirst().reduce(
            CGRect(origin: points[0], size: .zero)
        ) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard box.width >= minimumSpan || box.height >= minimumSpan else { return nil }
        guard let first = points.first, let last = points.last else { return nil }
        return first == last ? points : points + [first]
    }

    /// The bounding box of everything caught, grown by `padding` — where the
    /// marching-ants outline and the action menu are anchored.
    public static func bounds(of rects: [CGRect], padding: CGFloat = 8) -> CGRect? {
        let real = rects.filter { !$0.isNull && !$0.isEmpty }
        guard let first = real.first else { return nil }
        let union = real.dropFirst().reduce(first) { $0.union($1) }
        return union.insetBy(dx: -padding, dy: -padding)
    }
}
