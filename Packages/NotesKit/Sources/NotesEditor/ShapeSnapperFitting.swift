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
        guard let fit = classify(points),
              let start = points.first, let end = points.last else { return nil }
        switch fit.shape {
        case .line: return [start, end]
        case .angle(let bend): return densify([start, bend, end])
        case .arc(let bulge): return arcPath(from: start, to: end, bulge: bulge)
        default:
            let frame = Frame(rotation: fit.rotation, pivot: fit.pivot)
            return path(for: fit.shape, in: fit.box).map(frame.toPage)
        }
    }

    /// What the ink was taken to be: the shape, the box it fills — in the shape's
    /// OWN frame — and that frame's tilt about `pivot` (0 for a shape drawn
    /// square to the page).
    struct Classification {
        var shape: Shape
        var box: CGRect
        var rotation: CGFloat = 0
        var pivot: CGPoint = .zero
    }

    /// A rotation about a pivot: page space ⇄ a tilted shape's own frame.
    struct Frame {
        var rotation: CGFloat
        var pivot: CGPoint

        func toFrame(_ point: CGPoint) -> CGPoint { turn(point, by: -rotation) }
        func toPage(_ point: CGPoint) -> CGPoint { turn(point, by: rotation) }

        private func turn(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
            guard angle != 0 else { return point }
            let dx = point.x - pivot.x, dy = point.y - pivot.y
            return CGPoint(
                x: pivot.x + dx * cos(angle) - dy * sin(angle),
                y: pivot.y + dx * sin(angle) + dy * cos(angle)
            )
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
    static func classify(_ points: [CGPoint]) -> Classification? {
        guard let start = points.first, let end = points.last else { return nil }
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > minimumSnapSize else { return nil }

        let closed = distance(start, end) < diagonal * 0.33

        if !closed {
            if isStraight(points) { return Classification(shape: .line, box: box) }
            return bestOpenShape(points, diagonal: diagonal).map { Classification(shape: $0, box: box) }
        }

        // Square to the page first — that is how almost everything is drawn, and
        // a hand-drawn box a few degrees off is meant upright.
        let upright = scoredClosedShape(points, in: box)
        var best = Classification(shape: upright.shape, box: box)
        // A shape drawn on a real slant — a tilted ellipse, a rectangle turned
        // 30° — is fitted in its own frame instead. Fitting it to the page's
        // axes kept the classification and lost the shape: a tilted ellipse
        // snapped to an upright one, fatter and pointing the wrong way.
        if let tilt = principalTilt(points) {
            let frame = Frame(rotation: tilt.angle, pivot: tilt.pivot)
            let turned = points.map(frame.toFrame)
            let turnedBox = boundingBox(turned)
            let tilted = scoredClosedShape(turned, in: turnedBox)
            if tilted.score + tiltPenalty < upright.score {
                best = Classification(
                    shape: tilted.shape, box: turnedBox, rotation: tilt.angle, pivot: tilt.pivot
                )
            }
        }
        return best
    }

    /// What an open stroke that isn't straight meant: one deliberate bend (an
    /// angle) or one smooth bow (an arc) — whichever its ink actually follows.
    ///
    /// Arcs used to have no candidate at all, so a drawn half circle either
    /// snapped to nothing or — when sampling noise read its curve as one
    /// corner — to a V. And an angle was accepted on a corner COUNT alone, with
    /// the bend at the sharpest local turn: hand tremor at a rounded corner
    /// counted as two corners (a quarter of drawn L's never snapped) while an S
    /// curve could count as one (and snapped to a V). Both are now measured the
    /// same way — how closely the ink follows the shape drawn through it.
    static func bestOpenShape(_ points: [CGPoint], diagonal: CGFloat) -> Shape? {
        guard let start = points.first, let end = points.last else { return nil }
        let sample = reduce(points)
        var candidates: [(shape: Shape, residual: CGFloat)] = []
        if let bend = furthestFromChord(points) {
            let legs = densify([start, bend, end])
            let residual = meanDistance(from: sample, to: legs) / diagonal
            if residual < angleTolerance { candidates.append((.angle(bendAt: bend), residual)) }
        }
        if let bulge = arcBulge(points) {
            let arc = arcPath(from: start, to: end, bulge: bulge)
            let residual = meanDistance(from: sample, to: arc) / diagonal
            // An arc has to be followed closely: a squiggle bows too, and an arc
            // is the one open shape that can't be told apart by its corners.
            if residual < arcTolerance { candidates.append((.arc(bulge: bulge), residual)) }
        }
        return candidates.min { $0.residual < $1.residual }?.shape
    }

    /// How closely the ink must follow a circular arc to be snapped to one, as a
    /// fraction of its size.
    static let arcTolerance: CGFloat = 0.03
    /// The same for two straight legs. A drawn L or V follows its legs to within
    /// about 0.01; an S curve or a half circle is nearer 0.08.
    static let angleTolerance: CGFloat = 0.03

    /// The corner of an angle: the point of the ink furthest from the straight
    /// line between its ends. Unlike the sharpest local turn, a wobble on one leg
    /// can't win this.
    static func furthestFromChord(_ points: [CGPoint]) -> CGPoint? {
        guard let start = points.first, let end = points.last, points.count > 2 else { return nil }
        return points.dropFirst().dropLast().max {
            perpendicularDistance($0, lineStart: start, lineEnd: end)
                < perpendicularDistance($1, lineStart: start, lineEnd: end)
        }
    }

    /// How much better a tilted fit has to be than an upright one to win.
    static let tiltPenalty: CGFloat = 0.004
    /// Within this of level/upright, a shape is taken to be drawn square.
    static let minimumTilt: CGFloat = .pi / 180 * 8
    /// How much longer than wide (by the spread of its ink) a shape must be for
    /// its axis to mean anything. A circle or a square has no direction.
    static let minimumElongation: CGFloat = 1.3

    /// The direction a closed shape's ink is stretched along, from the spread of
    /// its points (principal axes), when it is clearly stretched AND clearly
    /// tilted. Nil for anything round, square, or near enough upright.
    static func principalTilt(_ points: [CGPoint]) -> (angle: CGFloat, pivot: CGPoint)? {
        guard points.count > 2 else { return nil }
        let count = CGFloat(points.count)
        let mean = CGPoint(
            x: points.reduce(0) { $0 + $1.x } / count, y: points.reduce(0) { $0 + $1.y } / count
        )
        var xx: CGFloat = 0, yy: CGFloat = 0, xy: CGFloat = 0
        for point in points {
            let dx = point.x - mean.x, dy = point.y - mean.y
            xx += dx * dx; yy += dy * dy; xy += dx * dy
        }
        let spread = sqrt((xx - yy) * (xx - yy) + 4 * xy * xy)
        let major = (xx + yy + spread) / 2, minor = (xx + yy - spread) / 2
        guard minor > 0.0001, major / minor > minimumElongation * minimumElongation else { return nil }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        // Distance to the nearest of level and upright; a rectangle tilted 80° is
        // one tilted -10°.
        let quarter = CGFloat.pi / 2
        let offset = angle - (angle / quarter).rounded() * quarter
        guard abs(offset) > minimumTilt else { return nil }
        return (offset, mean)
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
        scoredClosedShape(points, in: box).shape
    }

    /// `bestClosedShape`, with how well it fit (mean residual over the box's
    /// diagonal, plus the candidate's penalty) — so an upright fit and a tilted
    /// one can be compared.
    ///
    /// Every candidate fills the same box, so they differ only in shape. The
    /// pentagon used to carry a 0.03 penalty on top of a pentagon that didn't even
    /// reach its box's edges: a drawn pentagon fitted it better than anything
    /// (0.022 against the ellipse's 0.034) and still lost every time. Triangles
    /// came only apex-up, so ▽ — and a right triangle with its right angle at the
    /// top — snapped to a circle.
    static func scoredClosedShape(_ points: [CGPoint], in box: CGRect) -> (shape: Shape, score: CGFloat) {
        let sample = reduce(points)
        let diagonal = max(hypot(box.width, box.height), 1)
        // Round beats angular on a tie: an ellipse is the shape people draw
        // fastest and least carefully, so its ink is the loosest.
        var candidates: [(shape: Shape, penalty: CGFloat)] = [(.ellipse, 0), (.rectangle, 0.012)]
        for side in Side.allCases {
            candidates.append((.triangle(apexFraction: apexFraction(points, in: box, side: side), apex: side), 0.012))
        }
        candidates += [
            (.polygon(sides: 4), 0.012),  // a diamond: a square stood on its corner
            (.polygon(sides: 5), 0.012),
            (.polygon(sides: 5, rotated: true), 0.014),
            // Little lighter: a hexagon is nearly round, so its fit is never far
            // ahead of the ellipse's — and a drawn circle is never near a hexagon.
            (.polygon(sides: 6), 0.004),
            (.polygon(sides: 6, rotated: true), 0.004)
        ]
        var best: (shape: Shape, score: CGFloat) = (.ellipse, .greatestFiniteMagnitude)
        for candidate in candidates {
            let outline = path(for: candidate.shape, in: box)
            let score = meanDistance(from: sample, to: outline) / diagonal + candidate.penalty
            if score < best.score { best = (candidate.shape, score) }
        }
        return best
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
        case .arc(let bulge):
            return arcPath(
                from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.maxY), bulge: bulge
            )
        case .ellipse:
            return ellipsePath(in: box)
        case .rectangle:
            return rectanglePath(in: box)
        case .triangle(let fraction, let side):
            return trianglePath(in: box, apexFraction: fraction, apex: side)
        case .polygon(let sides, let rotated):
            return polygonPath(in: box, sides: sides, rotated: rotated)
        }
    }

    /// Where the drawn apex sat along `side`, 0…1 — so a leaning triangle keeps
    /// its lean when it's resized. The apex is the ink that reaches furthest
    /// toward that side.
    private static func apexFraction(_ points: [CGPoint], in box: CGRect, side: Side = .top) -> CGFloat {
        let apex: CGPoint?
        switch side {
        case .top: apex = points.min { $0.y < $1.y }
        case .bottom: apex = points.max { $0.y < $1.y }
        case .left: apex = points.min { $0.x < $1.x }
        case .right: apex = points.max { $0.x < $1.x }
        }
        guard let apex else { return 0.5 }
        let fraction: CGFloat
        switch side {
        case .top, .bottom:
            guard box.width > 0 else { return 0.5 }
            fraction = (apex.x - box.minX) / box.width
        case .left, .right:
            guard box.height > 0 else { return 0.5 }
            fraction = (apex.y - box.minY) / box.height
        }
        return min(max(fraction, 0), 1)
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

    /// The apex on `apex`'s side of the box, the base along the opposite side.
    private static func trianglePath(in box: CGRect, apexFraction: CGFloat, apex side: Side) -> [CGPoint] {
        let corners: [CGPoint]
        switch side {
        case .top:
            let apex = CGPoint(x: box.minX + box.width * apexFraction, y: box.minY)
            corners = [apex, CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY), apex]
        case .bottom:
            let apex = CGPoint(x: box.minX + box.width * apexFraction, y: box.maxY)
            corners = [apex, CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), apex]
        case .left:
            let apex = CGPoint(x: box.minX, y: box.minY + box.height * apexFraction)
            corners = [apex, CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), apex]
        case .right:
            let apex = CGPoint(x: box.maxX, y: box.minY + box.height * apexFraction)
            corners = [apex, CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.minY), apex]
        }
        return densify(corners)
    }

    /// A regular polygon stretched to fill the box exactly, first vertex pointing
    /// up (or, `rotated`, half a step round so an edge sits on top). It used to be
    /// inscribed in the box's ellipse, which leaves a pentagon short of the box's
    /// bottom and sides — a worse fit to a drawn pentagon than a circle was.
    private static func polygonPath(in box: CGRect, sides: Int, rotated: Bool = false) -> [CGPoint] {
        guard sides >= 3 else { return rectanglePath(in: box) }
        let start = -CGFloat.pi / 2 + (rotated ? .pi / CGFloat(sides) : 0)
        let unit = (0...sides).map { index -> CGPoint in
            let angle = start + CGFloat(index) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: cos(angle), y: sin(angle))
        }
        let own = boundingBox(unit)
        guard own.width > 0, own.height > 0 else { return rectanglePath(in: box) }
        let corners = unit.map { point in
            CGPoint(
                x: box.minX + (point.x - own.minX) / own.width * box.width,
                y: box.minY + (point.y - own.minY) / own.height * box.height
            )
        }
        return densify(corners)
    }

    // MARK: - Arcs

    /// How far, and to which side, the ink bows away from the straight line
    /// between its ends — as a fraction of that line's length, signed to the LEFT
    /// of start → end. Nil when the ends coincide.
    static func arcBulge(_ points: [CGPoint]) -> CGFloat? {
        guard let start = points.first, let end = points.last else { return nil }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        // Signed distance off the chord: positive on the left (-dy, dx) side.
        var furthest: CGFloat = 0
        for point in points {
            let offset = ((point.x - start.x) * -dy + (point.y - start.y) * dx) / length
            if abs(offset) > abs(furthest) { furthest = offset }
        }
        return furthest / length
    }

    /// A circular arc from `start` to `end`, bowing `bulge` × their distance to
    /// the left of start → end (negative: to the right). Past 0.5 it is more than
    /// half a circle.
    static func arcPath(from start: CGPoint, to end: CGPoint, bulge: CGFloat) -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        let chord = hypot(dx, dy)
        let sagitta = abs(bulge) * chord
        guard chord > 0.0001, sagitta > 0.0001 else { return [start, end] }
        // Unit normal toward the bulge.
        let side: CGFloat = bulge >= 0 ? 1 : -1
        let normal = CGPoint(x: -dy / chord * side, y: dx / chord * side)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let radius = (chord * chord / 4 + sagitta * sagitta) / (2 * sagitta)
        // The centre sits on the normal through the chord's middle: behind the
        // chord for less than half a circle, in front of it for more.
        let centre = CGPoint(
            x: middle.x + normal.x * (sagitta - radius), y: middle.y + normal.y * (sagitta - radius)
        )
        let from = atan2(start.y - centre.y, start.x - centre.x)
        let to = atan2(end.y - centre.y, end.x - centre.x)
        let peak = atan2(normal.y, normal.x)
        // Go the way round that passes through the peak of the bow.
        let twoPi = 2 * CGFloat.pi
        func wrapped(_ angle: CGFloat) -> CGFloat {
            let turned = angle.truncatingRemainder(dividingBy: twoPi)
            return turned < 0 ? turned + twoPi : turned
        }
        let ahead = wrapped(to - from)
        let sweep = wrapped(peak - from) <= ahead ? ahead : ahead - twoPi
        let steps = max(8, Int(abs(sweep) * radius / 6))
        return (0...steps).map { index in
            let angle = from + sweep * CGFloat(index) / CGFloat(steps)
            return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
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

    /// Builds a new stroke tracing `path`, reusing the original stroke's ink and
    /// an average point size so it looks like it was drawn with the same pen.
    static func rebuild(_ original: PKStroke, along path: [CGPoint]) -> PKStroke {
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
        return PKStroke(ink: shapeSafeInk(original.ink), path: newPath)
    }

    private static func averageSize(_ points: [PKStrokePoint]) -> CGSize {
        var w: CGFloat = 0, h: CGFloat = 0
        for p in points { w += p.size.width; h += p.size.height }
        let n = CGFloat(points.count)
        return CGSize(width: w / n, height: h / n)
    }
}
