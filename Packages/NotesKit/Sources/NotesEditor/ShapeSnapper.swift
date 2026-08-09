import CoreGraphics
import Foundation
import PencilKit

/// Snaps a freehand stroke to a clean geometric shape when the user "holds" the
/// pencil at the end of the stroke — the same gesture as Apple Notes. The hold is
/// read from the stroke's own timing, then the path is fitted to a line, angle,
/// ellipse, rectangle, triangle or pentagon, preserving the ink.
enum ShapeSnapper {
    /// How long the pencil must rest at the end of a stroke for it to count as
    /// "hold to snap".
    static let minimumHold: TimeInterval = 0.4
    /// How far the pencil may drift during that rest and still be holding still.
    /// Generous, because a hand resting on glass is never actually still.
    static let holdRadius: CGFloat = 11
    /// How far the ink may wander off the straight line between its endpoints and
    /// still be snapped to that line. A deliberate hold is a statement of intent,
    /// so this is looser than a passive straightness test would be — but not so
    /// loose that a drawn arc collapses into a chord.
    static let straightTolerance: CGFloat = 0.15

    /// If `stroke` ends with a dwell and fits a primitive confidently, returns a
    /// replacement stroke; otherwise nil (leave the freehand stroke as drawn).
    ///
    /// This is the FALLBACK path, used when the live dwell watcher didn't catch
    /// the hold — the snap normally settles under the pencil while it's still
    /// down (see `StrokeDwellRecognizer`).
    static func snapped(_ stroke: PKStroke) -> PKStroke? {
        guard holdDuration(of: stroke) >= minimumHold else { return nil }
        let points = trimmedTail(densePoints(stroke))
        guard points.count >= 6, let path = fit(points) else { return nil }
        return rebuild(stroke, along: path)
    }

    // MARK: - Live, adjustable snapping

    /// The kind of shape a stroke settled into. Kept apart from the points it was
    /// fitted from so the SAME shape can be redrawn at a new size or angle while
    /// the pencil is still down.
    enum Shape: Equatable {
        case line
        /// A single deliberate bend, at a fraction along the way to the handle.
        case angle(bendAt: CGPoint)
        case ellipse
        case rectangle
        /// Apex position across the box, 0…1 — so a leaning triangle keeps leaning
        /// as it's resized.
        case triangle(apexFraction: CGFloat)
        case polygon(sides: Int)

        var isClosed: Bool {
            switch self {
            case .line, .angle: false
            default: true
            }
        }
    }

    /// A shape that has settled under a pencil which is STILL DOWN: the corner or
    /// end that stays put, and the one the pencil now holds.
    ///
    /// This is what makes a snap feel like a tool rather than a verdict. Snapping
    /// on release means the only way to change a circle's size is to undo it and
    /// draw again; here the pencil keeps the far end, so length, direction and size
    /// are still yours until you lift.
    struct LiveSnap: Equatable {
        var shape: Shape
        /// Fixed while the pencil drags.
        var anchor: CGPoint
        /// Where the pencil is; moving it redraws the shape.
        var handle: CGPoint
    }

    /// Classifies an in-progress path and works out which end the pencil holds.
    static func liveSnap(_ points: [CGPoint]) -> LiveSnap? {
        let trimmed = trimmedTail(points)
        guard trimmed.count >= 6, let (shape, box) = classify(trimmed),
              let start = trimmed.first, let rest = trimmed.last else { return nil }

        guard shape.isClosed else {
            return LiveSnap(shape: shape, anchor: start, handle: rest)
        }
        // A closed shape is sized by its box, so the pencil takes the corner
        // nearest where it stopped and the opposite corner stays put.
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)
        ]
        let handle = corners.min { distance($0, rest) < distance($1, rest) } ?? corners[2]
        let anchor = CGPoint(
            x: handle.x == box.minX ? box.maxX : box.minX,
            y: handle.y == box.minY ? box.maxY : box.minY
        )
        return LiveSnap(shape: shape, anchor: anchor, handle: handle)
    }

    /// The snap redrawn with the pencil somewhere new. Returns nil once the shape
    /// has been dragged down to nothing, so a stray flick can't collapse it.
    static func path(for snap: LiveSnap, handle: CGPoint) -> [CGPoint]? {
        let anchor = snap.anchor
        switch snap.shape {
        case .line:
            guard distance(anchor, handle) > 6 else { return nil }
            return [anchor, handle]
        case .angle(let bend):
            guard distance(anchor, handle) > 6 else { return nil }
            return densify([anchor, bend, handle])
        default:
            let box = CGRect(
                x: min(anchor.x, handle.x), y: min(anchor.y, handle.y),
                width: abs(handle.x - anchor.x), height: abs(handle.y - anchor.y)
            )
            guard box.width > 8, box.height > 8 else { return nil }
            return path(for: snap.shape, in: box)
        }
    }

    /// Rebuilds `original` along an already-fitted path — the commit half of the
    /// live snap, so the preview and the ink can't disagree.
    static func stroke(from path: [CGPoint], like original: PKStroke) -> PKStroke {
        rebuild(original, along: path)
    }

    // MARK: - Hold detection

    /// How long the pencil stayed put at the end of the stroke.
    ///
    /// Measured as the time since it was last farther than `holdRadius` from where
    /// it came to rest — NOT as the time spanned by the points inside a fixed
    /// trailing window.
    ///
    /// That distinction is the whole feature. `PKStrokePath` stores a FITTED
    /// spline, not the raw touch stream: a pencil held still needs no new control
    /// points, so PencilKit collapses a half-second dwell into a single point whose
    /// `timeOffset` simply jumps. A window scan then sees one point, measures a
    /// zero-length hold, and refuses every snap — which is exactly what shipped.
    ///
    /// Returns 0 for a stroke that never left `holdRadius` at all: that's a dot
    /// being placed, not a shape being drawn.
    static func holdDuration(of stroke: PKStroke) -> TimeInterval {
        let points = Array(stroke.path)
        guard let last = points.last else { return 0 }
        for point in points.reversed() where distance(point.location, last.location) > holdRadius {
            return max(0, last.timeOffset - point.timeOffset)
        }
        return 0
    }

    // MARK: - Sampling

    /// The stroke's geometry, densely and evenly sampled.
    ///
    /// Fitting has to read the spline, not its control points: a quick straight
    /// line can be four control points, and the old six-point floor threw those
    /// strokes away before they were ever looked at.
    static func densePoints(_ stroke: PKStroke) -> [CGPoint] {
        let path = stroke.path
        guard path.count > 1 else { return path.map(\.location) }
        return path.interpolatedPoints(by: .distance(2)).map(\.location)
    }

    /// Drops the dwell from the end of the path so the pause doesn't drag the fit
    /// toward the resting point, while keeping the true endpoint.
    static func trimmedTail(_ points: [CGPoint]) -> [CGPoint] {
        guard let last = points.last,
              let cut = points.lastIndex(where: { distance($0, last) > holdRadius }),
              cut < points.count - 1
        else { return points }
        return Array(points[0...cut]) + [last]
    }

    // MARK: - Fitting

    static func fit(_ points: [CGPoint]) -> [CGPoint]? {
        guard let (shape, box) = classify(points),
              let start = points.first, let end = points.last else { return nil }
        switch shape {
        case .line: return [start, end]
        case .angle(let bend): return densify([start, bend, end])
        default: return path(for: shape, in: box)
        }
    }

    /// What the ink looks like it was meant to be, and the box it occupies.
    static func classify(_ points: [CGPoint]) -> (shape: Shape, box: CGRect)? {
        guard let start = points.first, let end = points.last else { return nil }
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 24 else { return nil }

        let closed = distance(start, end) < diagonal * 0.28
        let corners = cornerCount(points, closed: closed)

        if !closed {
            if isStraight(points) { return (.line, box) }
            // One deliberate bend and nothing else: an angle, cleaned into two
            // straight legs rather than left as a wobble.
            if corners == 1, let bend = sharpestCorner(points) {
                return (.angle(bendAt: bend), box)
            }
            return nil
        }

        switch corners {
        // A closed shape with no clear corners is a circle, and one with a couple
        // is a lumpy circle — both read as "I meant an ellipse".
        case ...2: return (.ellipse, box)
        case 3: return (.triangle(apexFraction: apexFraction(points, in: box)), box)
        case 4: return (.rectangle, box)
        case 5: return (.polygon(sides: 5), box)
        // Six or more detected corners on a closed path is a scribbled round
        // shape, not a hexagon anybody meant to draw.
        default: return (.ellipse, box)
        }
    }

    /// A classified shape drawn at whatever size the box now is.
    static func path(for shape: Shape, in box: CGRect) -> [CGPoint] {
        switch shape {
        case .line:
            return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)]
        case .angle(let bend):
            return densify([
                CGPoint(x: box.minX, y: box.minY), bend, CGPoint(x: box.maxX, y: box.maxY)
            ])
        case .ellipse:
            return ellipsePath(in: box)
        case .rectangle:
            return rectanglePath(in: box)
        case .triangle(let fraction):
            return trianglePath(in: box, apexFraction: fraction)
        case .polygon(let sides):
            return polygonPath(in: box, sides: sides)
        }
    }

    /// Where the drawn apex sat across the box, 0…1 — so a leaning triangle keeps
    /// its lean when it's resized.
    private static func apexFraction(_ points: [CGPoint], in box: CGRect) -> CGFloat {
        guard box.width > 0, let apex = points.min(by: { $0.y < $1.y }) else { return 0.5 }
        return min(max((apex.x - box.minX) / box.width, 0), 1)
    }

    private static func ellipsePath(in box: CGRect) -> [CGPoint] {
        let cx = box.midX, cy = box.midY
        let rx = box.width / 2, ry = box.height / 2
        let segments = 64
        return (0...segments).map { index in
            let t = Double(index) / Double(segments) * 2 * .pi
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

    private static func trianglePath(in box: CGRect, apexFraction: CGFloat) -> [CGPoint] {
        // Apex across the top; base = the two bottom box corners.
        let apex = CGPoint(x: box.minX + box.width * apexFraction, y: box.minY)
        let corners = [
            CGPoint(x: apex.x, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: apex.x, y: box.minY)
        ]
        return densify(corners)
    }

    /// A regular polygon inscribed in the box, first vertex pointing up — which is
    /// how a pentagon gets drawn by hand.
    private static func polygonPath(in box: CGRect, sides: Int) -> [CGPoint] {
        guard sides >= 3 else { return rectanglePath(in: box) }
        let cx = box.midX, cy = box.midY
        let rx = box.width / 2, ry = box.height / 2
        let corners = (0...sides).map { index -> CGPoint in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: cx + rx * cos(angle), y: cy + ry * sin(angle))
        }
        return densify(corners)
    }

    /// Adds intermediate points along each segment so the rebuilt stroke has a
    /// smooth, evenly sampled path.
    private static func densify(_ corners: [CGPoint], step: CGFloat = 6) -> [CGPoint] {
        var out: [CGPoint] = []
        for index in 0..<(corners.count - 1) {
            let start = corners[index], end = corners[index + 1]
            let length = distance(start, end)
            let steps = max(1, Int(length / step))
            for sample in 0..<steps {
                let t = CGFloat(sample) / CGFloat(steps)
                out.append(CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                ))
            }
        }
        out.append(corners.last!)
        return out
    }

    // MARK: - Geometry helpers

    static func isStraight(_ points: [CGPoint]) -> Bool {
        guard let a = points.first, let b = points.last else { return false }
        let len = distance(a, b)
        guard len > 1 else { return false }
        // Max perpendicular deviation from the a→b line, normalized by length.
        var maxDev: CGFloat = 0
        for point in points {
            maxDev = max(maxDev, perpendicularDistance(point, lineStart: a, lineEnd: b))
        }
        return maxDev / len < straightTolerance
    }

    /// The point that turns the path most sharply — the corner of a hand-drawn
    /// angle. Endpoints are excluded so a hooked start never wins.
    private static func sharpestCorner(_ points: [CGPoint]) -> CGPoint? {
        let reduced = reduce(points)
        guard reduced.count >= 3 else { return nil }
        var best: (angle: CGFloat, point: CGPoint)?
        for j in 1..<(reduced.count - 1) {
            let v1 = CGVector(dx: reduced[j].x - reduced[j - 1].x, dy: reduced[j].y - reduced[j - 1].y)
            let v2 = CGVector(dx: reduced[j + 1].x - reduced[j].x, dy: reduced[j + 1].y - reduced[j].y)
            let angle = abs(angleBetween(v1, v2))
            if best == nil || angle > best!.angle { best = (angle, reduced[j]) }
        }
        return best?.point
    }

    /// Counts sharp direction changes (> ~50°) along the path — used to tell an
    /// ellipse (few) from a rectangle (≈4) or triangle (≈3).
    ///
    /// A closed path is read as a RING. An open one has no turn at its endpoints,
    /// but a closed one turns where its ends meet exactly like it does anywhere
    /// else, and skipping that join cost every hand-drawn square its fourth
    /// corner — so squares were snapping to triangles.
    static func cornerCount(_ points: [CGPoint], closed: Bool = false) -> Int {
        var reduced = reduce(points)
        guard reduced.count >= 3 else { return 0 }

        if closed, reduced.count > 3 {
            // Where the ends meet they're one corner sampled twice, not two.
            let box = boundingBox(reduced)
            let join = hypot(box.width, box.height) * 0.05
            if distance(reduced[0], reduced[reduced.count - 1]) < join { reduced.removeLast() }
        }

        let n = reduced.count
        guard n >= 3 else { return 0 }
        let indices = closed ? Array(0..<n) : Array(1..<(n - 1))
        var corners: [Int] = []
        for j in indices {
            let previous = reduced[(j - 1 + n) % n]
            let next = reduced[(j + 1) % n]
            let v1 = CGVector(dx: reduced[j].x - previous.x, dy: reduced[j].y - previous.y)
            let v2 = CGVector(dx: next.x - reduced[j].x, dy: next.y - reduced[j].y)
            guard abs(angleBetween(v1, v2)) > .pi * 0.28 else { continue }
            // One corner spread over a couple of samples is still one corner.
            if let last = corners.last, j - last < 2 { continue }
            corners.append(j)
        }
        // Same rule across the ring's seam.
        if closed, corners.count > 1, let first = corners.first, let last = corners.last,
           (first + n) - last < 2 {
            corners.removeLast()
        }
        return corners.count
    }

    /// Down-samples to at most ~48 points so corner detection reads the shape's
    /// overall turns rather than the sampling noise between them.
    private static func reduce(_ points: [CGPoint]) -> [CGPoint] {
        let stride = max(1, points.count / 48)
        var reduced: [CGPoint] = []
        var i = 0
        while i < points.count {
            reduced.append(points[i])
            i += stride
        }
        return reduced
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
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
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
