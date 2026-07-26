import CoreGraphics
import Foundation
import PencilKit

/// Snaps a freehand stroke to a clean geometric shape when the user "holds" the
/// pencil at the end of the stroke — the same gesture as Apple Notes. We detect
/// the hold from the stroke's own timing (the tail dwells in one spot), then fit
/// the path to a line, ellipse, rectangle, or triangle, preserving the ink.
enum ShapeSnapper {

    /// If `stroke` ends with a dwell and fits a primitive confidently, returns a
    /// replacement stroke; otherwise nil (leave the freehand stroke as drawn).
    static func snapped(_ stroke: PKStroke) -> PKStroke? {
        let points = sample(stroke)
        guard points.count >= 8 else { return nil }
        guard endedWithHold(stroke) else { return nil }
        // Drop the dwell tail so it doesn't distort the fit.
        let shapePoints = trimmedTail(points)
        guard shapePoints.count >= 6 else { return nil }
        guard let path = fit(shapePoints) else { return nil }
        return rebuild(stroke, along: path)
    }

    // MARK: - Hold detection

    /// True when the last ~0.3s of the stroke stayed within a small radius —
    /// i.e. the pencil paused at the end (the intent-to-snap signal).
    private static func endedWithHold(_ stroke: PKStroke) -> Bool {
        let pts = Array(stroke.path)
        guard let last = pts.last else { return false }
        let holdWindow: TimeInterval = 0.28
        let holdRadius: CGFloat = 9
        var dwellStart: PKStrokePoint?
        for point in pts.reversed() {
            if last.timeOffset - point.timeOffset > holdWindow { break }
            if distance(point.location, last.location) > holdRadius { return false }
            dwellStart = point
        }
        guard let start = dwellStart else { return false }
        return last.timeOffset - start.timeOffset >= holdWindow * 0.75
    }

    private static func trimmedTail(_ points: [CGPoint]) -> [CGPoint] {
        guard let last = points.last else { return points }
        var result = points
        while result.count > 6, distance(result[result.count - 2], last) < 9 {
            result.removeLast()
        }
        return result
    }

    // MARK: - Sampling

    private static func sample(_ stroke: PKStroke) -> [CGPoint] {
        stroke.path.map { $0.location }
    }

    // MARK: - Fitting

    private static func fit(_ points: [CGPoint]) -> [CGPoint]? {
        let start = points.first!
        let end = points.last!
        let box = boundingBox(points)
        let diag = hypot(box.width, box.height)
        guard diag > 24 else { return nil }

        let closed = distance(start, end) < diag * 0.28
        let corners = cornerCount(points)

        if !closed {
            // Open stroke: snap to a straight line only if it's actually straight.
            return isStraight(points) ? [start, end] : nil
        }

        switch corners {
        case ...1:
            return ellipsePath(in: box)
        case 3:
            return trianglePath(points, in: box)
        default:
            return rectanglePath(in: box)
        }
    }

    private static func ellipsePath(in box: CGRect) -> [CGPoint] {
        let cx = box.midX, cy = box.midY
        let rx = box.width / 2, ry = box.height / 2
        let segments = 64
        return (0...segments).map { i in
            let t = Double(i) / Double(segments) * 2 * .pi
            return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
        }
    }

    private static func rectanglePath(in box: CGRect) -> [CGPoint] {
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.minX, y: box.minY)
        ]
        return densify(corners)
    }

    private static func trianglePath(_ points: [CGPoint], in box: CGRect) -> [CGPoint] {
        // Apex = highest point; base = the two bottom box corners.
        let apex = points.min(by: { $0.y < $1.y }) ?? CGPoint(x: box.midX, y: box.minY)
        let corners = [
            CGPoint(x: apex.x, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: apex.x, y: box.minY)
        ]
        return densify(corners)
    }

    /// Adds intermediate points along each segment so the rebuilt stroke has a
    /// smooth, evenly sampled path.
    private static func densify(_ corners: [CGPoint], step: CGFloat = 6) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0..<(corners.count - 1) {
            let a = corners[i], b = corners[i + 1]
            let len = distance(a, b)
            let n = max(1, Int(len / step))
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        out.append(corners.last!)
        return out
    }

    // MARK: - Geometry helpers

    private static func isStraight(_ points: [CGPoint]) -> Bool {
        let a = points.first!, b = points.last!
        let len = distance(a, b)
        guard len > 1 else { return false }
        // Max perpendicular deviation from the a→b line, normalized by length.
        var maxDev: CGFloat = 0
        for p in points {
            let dev = perpendicularDistance(p, lineStart: a, lineEnd: b)
            maxDev = max(maxDev, dev)
        }
        return maxDev / len < 0.12
    }

    /// Counts sharp direction changes (> ~50°) along the path — used to tell an
    /// ellipse (few) from a rectangle (≈4) or triangle (≈3).
    private static func cornerCount(_ points: [CGPoint]) -> Int {
        let stride = max(1, points.count / 48)
        var reduced: [CGPoint] = []
        var i = 0
        while i < points.count { reduced.append(points[i]); i += stride }
        guard reduced.count >= 3 else { return 0 }
        var count = 0
        var lastCornerIndex = -3
        for j in 1..<(reduced.count - 1) {
            let v1 = CGVector(dx: reduced[j].x - reduced[j - 1].x, dy: reduced[j].y - reduced[j - 1].y)
            let v2 = CGVector(dx: reduced[j + 1].x - reduced[j].x, dy: reduced[j + 1].y - reduced[j].y)
            let angle = abs(angleBetween(v1, v2))
            if angle > .pi * 0.28, j - lastCornerIndex >= 2 {
                count += 1
                lastCornerIndex = j
            }
        }
        return count
    }

    private static func angleBetween(_ a: CGVector, _ b: CGVector) -> CGFloat {
        let dot = a.dx * b.dx + a.dy * b.dy
        let magA = hypot(a.dx, a.dy), magB = hypot(b.dx, b.dy)
        guard magA > 0.0001, magB > 0.0001 else { return 0 }
        return acos(max(-1, min(1, dot / (magA * magB))))
    }

    private static func perpendicularDistance(_ p: CGPoint, lineStart a: CGPoint, lineEnd b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let denom = hypot(dx, dy)
        guard denom > 0.0001 else { return distance(p, a) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / denom
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - Rebuild

    /// Builds a new stroke tracing `path`, reusing the original stroke's ink and
    /// an average point size so it looks like it was drawn with the same pen.
    private static func rebuild(_ original: PKStroke, along path: [CGPoint]) -> PKStroke {
        let source = Array(original.path)
        let avgSize = source.isEmpty
            ? CGSize(width: 3, height: 3)
            : averageSize(source)
        let force: CGFloat = source.first?.force ?? 1
        let controlPoints: [PKStrokePoint] = path.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.01,
                size: avgSize,
                opacity: 1,
                force: force,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let newPath = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        return PKStroke(ink: original.ink, path: newPath)
    }

    private static func averageSize(_ points: [PKStrokePoint]) -> CGSize {
        var w: CGFloat = 0, h: CGFloat = 0
        for p in points { w += p.size.width; h += p.size.height }
        let n = CGFloat(points.count)
        return CGSize(width: w / n, height: h / n)
    }
}
