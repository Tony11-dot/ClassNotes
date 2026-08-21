import CoreGraphics
import Foundation
import PencilKit

/// Fitting freehand ink to a primitive, and drawing that primitive at any size.
///
/// Split out of `ShapeSnapper` itself so the two halves stay readable: that file
/// is about the GESTURE — the hold, the live snap, the assists — and this one is
/// about the geometry that decides which shape the ink meant and lays it out.
extension ShapeSnapper {
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

    /// The smallest a stroke's own bounding box may be and still be eligible to
    /// snap at all — see `classify`.
    ///
    /// This used to be 24: comfortably smaller than a single ordinary letter.
    /// A straight-sided letter's downstroke (l, t, i, 1, L…) at normal
    /// handwriting size — or the crossbar of a "t" — routinely spans more than
    /// that on its own, so a hand-writing pause that rested long enough (see
    /// `StrokeDwellRecognizer.minimumHold`) was handed a stroke that ALREADY
    /// satisfied this gate before timing was ever the deciding factor. Raising
    /// the dwell time alone (Build 42) cut the false positives that were purely
    /// about timing, but couldn't fix the ones where the ink itself was small
    /// enough to read as a shape no matter how long the pause was measured —
    /// which is why writing could still snap into a line or an angle, why the
    /// vanishing kept being reported, and why beautification (fed mangled
    /// geometry instead of the letters that were actually written) got LESS
    /// accurate, not more. A deliberate hold-to-snap is drawn as its own
    /// gesture, separate from a line of writing, and is comfortably bigger than
    /// one letter in practice — this is set above ordinary letter size with
    /// real margin, not merely above it.
    static let minimumSnapSize: CGFloat = 46

    /// What the ink looks like it was meant to be, and the box it occupies.
    static func classify(_ points: [CGPoint]) -> (shape: Shape, box: CGRect)? {
        guard let start = points.first, let end = points.last else { return nil }
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > minimumSnapSize else { return nil }

        let closed = distance(start, end) < diagonal * 0.33

        if !closed {
            if isStraight(points) { return (.line, box) }
            // One deliberate bend and nothing else: an angle, cleaned into two
            // straight legs rather than left as a wobble.
            if cornerCount(points, closed: false) == 1, let bend = sharpestCorner(points) {
                return (.angle(bendAt: bend), box)
            }
            return nil
        }
        return (bestClosedShape(points, in: box), box)
    }

    /// Which primitive the closed ink actually resembles, decided by DRAWING each
    /// candidate at the ink's own size and measuring how far the ink strays from
    /// it.
    ///
    /// Counting corners is the obvious way to do this and it does not work. A
    /// hand-drawn square's corners are rounded, its sides bow, and the down-sample
    /// that stops sampling noise reading as corners can land either side of a real
    /// one — so the count came out as three about as often as four, and squares
    /// snapped to triangles. Fit residual asks the question the user is actually
    /// asking ("which of these did I mean?") and a square is nowhere near a
    /// triangle however its corners were drawn.
    static func bestClosedShape(_ points: [CGPoint], in box: CGRect) -> Shape {
        let sample = reduce(points)
        let diagonal = max(hypot(box.width, box.height), 1)
        let candidates: [(shape: Shape, penalty: CGFloat)] = [
            // Round beats angular on a tie: an ellipse is the shape people draw
            // fastest and least carefully, so its ink is the loosest.
            (.ellipse, 0),
            (.rectangle, 0.012),
            (.triangle(apexFraction: apexFraction(points, in: box)), 0.012),
            (.polygon(sides: 5), 0.03)
        ]
        var best: (shape: Shape, score: CGFloat)?
        for candidate in candidates {
            let outline = path(for: candidate.shape, in: box)
            let residual = meanDistance(from: sample, to: outline) / diagonal
            let score = residual + candidate.penalty
            if best == nil || score < best!.score { best = (candidate.shape, score) }
        }
        return best?.shape ?? .ellipse
    }

    /// Mean distance from each point to the nearest place on `outline`.
    static func meanDistance(from points: [CGPoint], to outline: [CGPoint]) -> CGFloat {
        guard !points.isEmpty, outline.count > 1 else { return .greatestFiniteMagnitude }
        var total: CGFloat = 0
        for point in points {
            var nearest = CGFloat.greatestFiniteMagnitude
            for index in 0..<(outline.count - 1) {
                nearest = min(nearest, distance(point, to: outline[index], outline[index + 1]))
            }
            total += nearest
        }
        return total / CGFloat(points.count)
    }

    /// Distance from a point to the segment a→b (not the infinite line).
    private static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return distance(p, a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
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
    static func densify(_ corners: [CGPoint], step: CGFloat = 6) -> [CGPoint] {
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

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - Rebuild

    /// Builds a new stroke tracing `path`, reusing an average point size so it
    /// looks like it was drawn with the same pen. Ink comes from `original`
    /// unless `ink` overrides it.
    ///
    /// The override exists for `commitSettledShape`'s replace branch: while a
    /// shape is held, `suppressLiveInk` swaps the live tool for an invisible
    /// copy of itself so the raw wandering stroke doesn't show through the
    /// preview, and `original` there is exactly that hidden stroke — its own
    /// `ink` is the transparent one. Rebuilding along its ink unchanged would
    /// commit an invisible shape. `pendingSnapInk`, captured before the swap,
    /// is what has to win instead. Every other caller (the deferred ruling/pen-
    /// shaping fallback in `runInkPass`, which never touches a suppressed
    /// stroke) passes no override and keeps rebuilding along the ink actually
    /// drawn with, same as before.
    static func rebuild(_ original: PKStroke, along path: [CGPoint], ink: PKInk? = nil) -> PKStroke {
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
        return PKStroke(ink: shapeSafeInk(ink ?? original.ink), path: newPath)
    }

    private static func averageSize(_ points: [PKStrokePoint]) -> CGSize {
        var w: CGFloat = 0, h: CGFloat = 0
        for p in points { w += p.size.width; h += p.size.height }
        let n = CGFloat(points.count)
        return CGSize(width: w / n, height: h / n)
    }
}
