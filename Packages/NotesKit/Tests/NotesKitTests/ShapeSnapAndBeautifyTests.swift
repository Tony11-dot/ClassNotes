import CoreGraphics
import Foundation
import NotesModels
import PencilKit
import Testing
import UIKit
@testable import NotesEditor
@testable import NotesServices

/// Builds a stroke from explicit (location, time) control points, which is how
/// PencilKit actually stores a path — a fitted spline, not the raw touch stream.
private func stroke(_ points: [(CGPoint, TimeInterval)]) -> PKStroke {
    let controls = points.map { location, time in
        PKStrokePoint(
            location: location, timeOffset: time,
            size: CGSize(width: 3, height: 3), opacity: 1,
            force: 1, azimuth: 0, altitude: .pi / 2
        )
    }
    return PKStroke(
        ink: PKInk(.pen, color: .black),
        path: PKStrokePath(controlPoints: controls, creationDate: Date())
    )
}

/// A straight run of points from `a` to `b`, sampled every `steps`, ending at
/// `duration`.
private func line(
    from a: CGPoint, to b: CGPoint, steps: Int = 12, duration: TimeInterval = 0.5
) -> [(CGPoint, TimeInterval)] {
    (0...steps).map { index in
        let t = CGFloat(index) / CGFloat(steps)
        return (
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
            duration * TimeInterval(t)
        )
    }
}

@Suite("Hold-to-snap shapes")
struct ShapeSnapperTests {

    @Test("A dwell PencilKit collapsed into one control point still reads as a hold")
    func holdSurvivesSplineCollapse() {
        // The exact shape of the bug: the pencil drew to (300, 100) and then sat
        // there for six tenths of a second, and PencilKit — which stores a fitted
        // spline, not the touch stream — recorded that entire rest as ONE extra
        // control point whose timeOffset simply jumps.
        var points = line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100))
        points.append((CGPoint(x: 300, y: 100), 1.6))

        #expect(ShapeSnapper.holdDuration(of: stroke(points)) >= 1.0)
        #expect(ShapeSnapper.holdDuration(of: stroke(points)) >= ShapeSnapper.minimumHold)
    }

    @Test("A stroke that ended the moment it stopped moving is not a hold")
    func noHoldWhenPencilLiftsImmediately() {
        let points = line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100))
        #expect(ShapeSnapper.holdDuration(of: stroke(points)) < ShapeSnapper.minimumHold)
        #expect(ShapeSnapper.snapped(stroke(points)) == nil)
    }

    @Test("A dot held in place is a dot, not a shape")
    func dotIsNeverSnapped() {
        let points: [(CGPoint, TimeInterval)] = [
            (CGPoint(x: 100, y: 100), 0),
            (CGPoint(x: 101, y: 100), 0.1),
            (CGPoint(x: 100, y: 101), 1.4)
        ]
        #expect(ShapeSnapper.holdDuration(of: stroke(points)) == 0)
        #expect(ShapeSnapper.snapped(stroke(points)) == nil)
    }

    @Test("A wobbly line held at the end comes out straight")
    func wobblyLineStraightens() {
        // Hand-drawn: drifts a few points off the true line on the way across.
        var points: [(CGPoint, TimeInterval)] = (0...16).map { index in
            let t = CGFloat(index) / 16
            let x = 100 + t * 240
            let y = 200 + sin(t * .pi * 2) * 5
            return (CGPoint(x: x, y: y), TimeInterval(t) * 0.6)
        }
        points.append((CGPoint(x: 340, y: 200), 1.7))

        guard let snapped = ShapeSnapper.snapped(stroke(points)) else {
            Issue.record("a line held at the end should snap")
            return
        }
        let locations = Array(snapped.path).map(\.location)
        #expect(locations.count >= 2)
        // Every point of the result sits on the line between its own endpoints.
        let first = locations.first!, last = locations.last!
        let span = hypot(last.x - first.x, last.y - first.y)
        for point in locations {
            let deviation = abs(
                (last.y - first.y) * point.x - (last.x - first.x) * point.y
                + last.x * first.y - last.y * first.x
            ) / span
            #expect(deviation < 0.5, "snapped line should be exactly straight")
        }
    }

    @Test("Live snapping smooths raw touch jitter before classifying, matching the release path")
    func liveSnapSmoothsJitterBeforeClassifying() {
        // Real touch samples carry tremor a fitted PencilKit spline doesn't —
        // high frequency, alternating sign, exactly what a moving average
        // cancels out. Left raw, this reads as too wobbly to be a line; the
        // live dwell watcher used to classify exactly this raw path (see
        // `CanvasSnapPreview.previewSnap`), which is why a hold only ever
        // seemed to resolve once the pencil lifted and the release path
        // classified PencilKit's already-smoothed spline instead.
        var raw: [CGPoint] = (0..<20).map { index in
            let t = CGFloat(index) / 19
            let x = 100 + t * 240
            let y: CGFloat = 200 + (index % 2 == 0 ? 45 : -45)
            return CGPoint(x: x, y: y)
        }
        raw[0] = CGPoint(x: 100, y: 200)
        raw[raw.count - 1] = CGPoint(x: 340, y: 200)

        #expect(
            ShapeSnapper.liveSnap(raw)?.shape != .line,
            "raw jitter this size shouldn't already read as straight"
        )

        let smoothed = StrokeSmoothing.smooth(raw, window: 7)
        guard let snap = ShapeSnapper.liveSnap(smoothed) else {
            Issue.record("smoothed jitter should classify as a line")
            return
        }
        #expect(snap.shape == .line)
    }

    @Test("A short, fast line has too few control points to fit — and is snapped anyway")
    func shortLineIsNotRejectedForPointCount() {
        // Four control points is all a quick flick leaves behind. The old
        // implementation fitted the control points directly and required eight,
        // so exactly the strokes people flick out were the ones it ignored.
        var points: [(CGPoint, TimeInterval)] = [
            (CGPoint(x: 100, y: 400), 0),
            (CGPoint(x: 160, y: 402), 0.05),
            (CGPoint(x: 220, y: 399), 0.1),
            (CGPoint(x: 280, y: 401), 0.15)
        ]
        points.append((CGPoint(x: 280, y: 401), 1.25))

        #expect(ShapeSnapper.densePoints(stroke(points)).count > 8)
        #expect(ShapeSnapper.snapped(stroke(points)) != nil)
    }

    @Test("Trimming the dwell keeps the stroke's real endpoint")
    func trimmingKeepsEndpoint() {
        let path = [
            CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0),
            // The dwell: three samples piled up at the end.
            CGPoint(x: 148, y: 0), CGPoint(x: 149, y: 1), CGPoint(x: 150, y: 0)
        ]
        let trimmed = ShapeSnapper.trimmedTail(path)
        #expect(trimmed.last == CGPoint(x: 150, y: 0))
        #expect(trimmed.count < path.count)
    }

    @Test("Closed shapes are classified by their corners")
    func classifiesClosedShapes() {
        func closedPath(_ corners: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            for index in 0..<(corners.count - 1) {
                let a = corners[index], b = corners[index + 1]
                for step in 0..<24 {
                    let t = CGFloat(step) / 24
                    out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
            }
            out.append(corners.last!)
            return out
        }

        // Four corners, and the one the pen started on counts — reading the path
        // as a line instead of a ring loses it, and the square becomes a triangle.
        let square = closedPath([
            CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0),
            CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 200), CGPoint(x: 0, y: 0)
        ])
        #expect(ShapeSnapper.cornerCount(square, closed: true) == 4)
        #expect(ShapeSnapper.fit(square)?.count ?? 0 > 4, "a square snaps to a rectangle")

        let triangle = closedPath([
            CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 180),
            CGPoint(x: 0, y: 180), CGPoint(x: 100, y: 0)
        ])
        #expect(ShapeSnapper.cornerCount(triangle, closed: true) == 3)

        let circle = (0...72).map { index -> CGPoint in
            let t = Double(index) / 72 * 2 * .pi
            return CGPoint(x: 100 + 100 * cos(t), y: 100 + 100 * sin(t))
        }
        #expect(ShapeSnapper.cornerCount(circle, closed: true) <= 2)
        // A circle fits to an ellipse: many points, none of them corners.
        let fitted = ShapeSnapper.fit(circle)
        #expect(fitted != nil)
        #expect((fitted?.count ?? 0) > 32)
    }

    @Test("A snapped line keeps its start and hands the pencil the other end")
    func lineHandleFollowsThePencil() throws {
        // Drawn left to right, then rested at the far end.
        let drawn = (0...40).map { CGPoint(x: 100 + CGFloat($0) * 8, y: 300) }
        let snap = try #require(ShapeSnapper.liveSnap(drawn))
        #expect(snap.shape == .line)
        #expect(snap.anchor == CGPoint(x: 100, y: 300), "the end it started from stays put")

        // Drag the pencil somewhere else entirely: same line, new length and angle.
        let moved = try #require(ShapeSnapper.path(for: snap, handle: CGPoint(x: 260, y: 120)))
        #expect(moved.first == snap.anchor)
        #expect(moved.last == CGPoint(x: 260, y: 120))

        // Dragged back onto its own start it would be nothing at all, so it isn't
        // drawn — a flick of the wrist must not be able to erase the shape.
        #expect(ShapeSnapper.path(for: snap, handle: CGPoint(x: 101, y: 301)) == nil)
    }

    @Test("A snapped closed shape resizes from the opposite corner")
    func closedShapeResizesFromItsAnchor() throws {
        let circle = (0...72).map { index -> CGPoint in
            let t = Double(index) / 72 * 2 * .pi
            return CGPoint(x: 200 + 100 * cos(t), y: 300 + 100 * sin(t))
        }
        let snap = try #require(ShapeSnapper.liveSnap(circle))
        #expect(snap.shape == .ellipse)
        // Anchor and handle are opposite corners of the shape's box.
        #expect(snap.anchor.x != snap.handle.x)
        #expect(snap.anchor.y != snap.handle.y)

        let bigger = try #require(ShapeSnapper.path(
            for: snap, handle: CGPoint(x: snap.anchor.x + 400, y: snap.anchor.y + 400)
        ))
        let box = bounds(of: bigger)
        #expect(abs(box.width - 400) < 1, "the box now spans anchor → pencil")
        #expect(abs(box.height - 400) < 1)
        // Collapsed onto the anchor there is no shape left to draw.
        #expect(ShapeSnapper.path(for: snap, handle: snap.anchor) == nil)
    }

    @Test("A resized rectangle is still a rectangle, and a triangle keeps its lean")
    func resizingKeepsTheShape() {
        let box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let rectangle = ShapeSnapper.path(for: .rectangle, in: box)
        #expect(abs(bounds(of: rectangle).width - 300) < 0.01)

        // Apex a quarter of the way across stays a quarter of the way across.
        let leaning = ShapeSnapper.path(for: .triangle(apexFraction: 0.25), in: box)
        let apex = leaning.min { $0.y < $1.y }
        #expect(abs((apex?.x ?? 0) - 75) < 1)
    }

    private func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Which closed shape did they mean?

    /// A hand-drawn outline of `shape`: the ideal path, jittered, with rounded
    /// corners and an imperfect closure — what actually comes off a pencil.
    private func handDrawn(_ shape: ShapeSnapper.Shape, in box: CGRect) -> [CGPoint] {
        let ideal = ShapeSnapper.path(for: shape, in: box)
        var generator = SystemRandomNumberGenerator()
        return ideal.enumerated().map { index, point in
            let wobble = CGFloat.random(in: -2.5...2.5, using: &generator)
            _ = index
            return CGPoint(x: point.x + wobble, y: point.y + wobble)
        }
    }

    @Test("A square snaps to a rectangle, not a triangle")
    func squareStaysASquare() {
        // The bug this pins: corner counting on a down-sampled ring lost a corner
        // about as often as it found it, so hand-drawn squares came back as
        // triangles. Fit residual can't confuse the two — a square's ink is
        // nowhere near a triangle's outline.
        let box = CGRect(x: 100, y: 100, width: 240, height: 240)
        for _ in 0..<12 {
            let ink = handDrawn(.rectangle, in: box)
            #expect(ShapeSnapper.bestClosedShape(ink, in: box) == .rectangle)
        }
    }

    @Test("A circle stays a circle and a triangle stays a triangle")
    func theOtherClosedShapes() {
        let box = CGRect(x: 100, y: 100, width: 220, height: 220)
        for _ in 0..<8 {
            #expect(ShapeSnapper.bestClosedShape(handDrawn(.ellipse, in: box), in: box) == .ellipse)
        }
        for _ in 0..<8 {
            let ink = handDrawn(.triangle(apexFraction: 0.5), in: box)
            if case .triangle = ShapeSnapper.bestClosedShape(ink, in: box) {
                // as expected
            } else {
                Issue.record("a drawn triangle came back as something else")
            }
        }
    }

    @Test("A drawn square classifies as a rectangle end to end")
    func classifyReadsASquare() {
        let box = CGRect(x: 100, y: 100, width: 200, height: 200)
        let ink = handDrawn(.rectangle, in: box)
        #expect(ShapeSnapper.classify(ink)?.shape == .rectangle)
    }

    // MARK: - Level and upright detents

    @Test("A held line clicks onto level and upright, keeping its length")
    func lineDetents() {
        let anchor = CGPoint(x: 100, y: 100)
        // Two degrees off level: pulled flat, same length.
        let nearlyLevel = CGPoint(x: 300, y: 107)
        let flat = ShapeSnapper.detented(nearlyLevel, from: anchor)
        #expect(flat.isDetent)
        #expect(abs(flat.point.y - anchor.y) < 0.01)
        #expect(abs(hypot(flat.point.x - anchor.x, flat.point.y - anchor.y)
                    - hypot(nearlyLevel.x - anchor.x, nearlyLevel.y - anchor.y)) < 0.01)

        let nearlyUpright = ShapeSnapper.detented(CGPoint(x: 106, y: 300), from: anchor)
        #expect(nearlyUpright.isDetent)
        #expect(abs(nearlyUpright.point.x - anchor.x) < 0.01)
    }

    @Test("A line drawn on a slant is left on its slant")
    func noDetentOffAxis() {
        let anchor = CGPoint(x: 100, y: 100)
        let diagonal = CGPoint(x: 300, y: 260)
        let result = ShapeSnapper.detented(diagonal, from: anchor)
        #expect(!result.isDetent)
        #expect(result.point == diagonal)
    }

    @Test("The detent applies to the committed path, not only the feel")
    func detentReachesThePath() {
        let snap = ShapeSnapper.LiveSnap(
            shape: .line,
            anchor: CGPoint(x: 100, y: 100),
            handle: CGPoint(x: 300, y: 104)
        )
        let path = ShapeSnapper.path(for: snap, handle: CGPoint(x: 300, y: 104))
        #expect(path?.count == 2)
        #expect(abs((path?.last?.y ?? 0) - 100) < 0.01, "the line that clicked flat is drawn flat")
    }

    @Test("Near the axis the line resists leaving it, without clicking onto it")
    func detentResists() {
        // Between the snap zone and the magnet's edge the pencil is followed, but
        // not exactly: the line is eased back toward level. A detent with no pull
        // is a cliff — dead until it suddenly grabs — and a straight-edge you can
        // feel for is the whole point of having one.
        let anchor = CGPoint(x: 100, y: 100)
        let eightDegrees = CGPoint(
            x: anchor.x + cos(.pi / 180 * 8) * 200,
            y: anchor.y + sin(.pi / 180 * 8) * 200
        )
        let pulled = ShapeSnapper.detented(eightDegrees, from: anchor)
        #expect(!pulled.isDetent, "it hasn't clicked on yet")
        let pulledAngle = atan2(pulled.point.y - anchor.y, pulled.point.x - anchor.x)
        #expect(pulledAngle < .pi / 180 * 8, "and it has been drawn back toward level")
        #expect(pulledAngle > 0, "but not all the way")
        // Length is never touched: it straightens, it doesn't also shorten.
        #expect(abs(hypot(pulled.point.x - anchor.x, pulled.point.y - anchor.y) - 200) < 0.01)
    }

    @Test("A nearly-square box clicks square, so a circle you meant is a circle")
    func squareDetent() {
        let anchor = CGPoint(x: 0, y: 0)
        let nearly = CGRect(x: 0, y: 0, width: 200, height: 192)
        let settled = ShapeSnapper.squared(nearly, anchoredAt: anchor)
        #expect(settled.isDetent)
        #expect(abs(settled.box.width - settled.box.height) < 0.001)
        #expect(settled.box.origin == anchor, "the corner the pencil isn't holding stays put")

        // An oblong is left an oblong.
        let oblong = CGRect(x: 0, y: 0, width: 300, height: 120)
        #expect(!ShapeSnapper.squared(oblong, anchoredAt: anchor).isDetent)
        #expect(ShapeSnapper.squared(oblong, anchoredAt: anchor).box == oblong)
    }

    @Test("A shape can be inked with no stroke to copy")
    func inksAShapeFromTheToolAlone() {
        // The live preview takes the wandering ink off the page, so by the time the
        // shape is committed PencilKit may have discarded the stroke it was
        // drawing. The shape still has to reach the page.
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        let built = ShapeSnapper.stroke(
            from: path, ink: PKInk(.pen, color: .red), width: 6
        )
        let points = Array(built.path)
        #expect(points.count == 2)
        #expect(points.first?.size.width == 6)
        #expect(built.ink.color.cgColor.alpha > 0)
    }

    @Test("An open stroke that is neither straight nor a single bend is left alone")
    func leavesFreehandAlone() {
        // A squiggle: three reversals, no clean primitive in it.
        let squiggle = (0...60).map { index -> CGPoint in
            let t = CGFloat(index) / 60
            return CGPoint(x: 100 + t * 300, y: 300 + sin(t * .pi * 6) * 60)
        }
        #expect(ShapeSnapper.fit(squiggle) == nil)
    }

    @Test("Screen-space tolerance converts to logical space by dividing out zoom")
    func holdRadiusConvertsByZoom() {
        #expect(ShapeSnapper.holdRadius(forTolerance: 22, zoomScale: 1) == 22)
        #expect(ShapeSnapper.holdRadius(forTolerance: 22, zoomScale: 2) == 11)
        #expect(abs(ShapeSnapper.holdRadius(forTolerance: 22, zoomScale: 0.5) - 44) < 0.001)
    }

    @Test("A zero or negative zoom never divides by zero")
    func holdRadiusGuardsDegenerateZoom() {
        #expect(ShapeSnapper.holdRadius(forTolerance: 22, zoomScale: 0).isFinite)
    }

    // MARK: - Every orientation, tilt and arc

    /// A deterministic hand: `corners` walked every ~2 points with a slow wobble
    /// on both axes, so the same ink comes out on every run.
    private func sketch(_ corners: [CGPoint], wobble: CGFloat = 2) -> [CGPoint] {
        var points: [CGPoint] = []
        for index in 0..<(corners.count - 1) {
            let a = corners[index], b = corners[index + 1]
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 2))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        points.append(corners[corners.count - 1])
        let count = CGFloat(points.count)
        return points.enumerated().map { index, point in
            let t = CGFloat(index) / count * 2 * .pi
            return CGPoint(x: point.x + wobble * sin(3 * t), y: point.y + wobble * cos(4 * t))
        }
    }

    /// `points` (offsets from `centre`) turned by `angle` and placed at `centre`.
    private func turned(_ points: [CGPoint], by angle: CGFloat, centre: CGPoint) -> [CGPoint] {
        let c = cos(angle), s = sin(angle)
        return points.map { point in
            let x: CGFloat = point.x * c - point.y * s
            let y: CGFloat = point.x * s + point.y * c
            return CGPoint(x: centre.x + x, y: centre.y + y)
        }
    }

    /// Where the path turns by more than about 30° — the corners of a polygon.
    private func corners(of path: [CGPoint]) -> [CGPoint] {
        guard path.count > 2 else { return path }
        var found = [path[0]]
        for index in 1..<(path.count - 1) {
            let before = atan2(path[index].y - path[index - 1].y, path[index].x - path[index - 1].x)
            let after = atan2(path[index + 1].y - path[index].y, path[index + 1].x - path[index].x)
            var turn = abs(after - before)
            if turn > .pi { turn = 2 * .pi - turn }
            if turn > 0.5 { found.append(path[index]) }
        }
        return found
    }

    private func regular(_ sides: Int, centre: CGPoint, radius: CGFloat, start: CGFloat) -> [CGPoint] {
        (0...sides).map { index in
            let angle = start + CGFloat(index) * 2 * .pi / CGFloat(sides)
            return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
    }

    @Test("A triangle pointing down snaps to one pointing down, not to a circle")
    func downwardTriangle() {
        let ink = sketch([
            CGPoint(x: 220, y: 240), CGPoint(x: 380, y: 240), CGPoint(x: 300, y: 380), CGPoint(x: 221, y: 241)
        ])
        guard case .triangle(_, let side)? = ShapeSnapper.classify(ink)?.shape else {
            Issue.record("▽ came back as \(String(describing: ShapeSnapper.classify(ink)?.shape))")
            return
        }
        #expect(side == .bottom)
    }

    @Test("A right triangle with its right angle at the top stays a right triangle")
    func rightTriangleAtTheTop() throws {
        let ink = sketch([
            CGPoint(x: 220, y: 220), CGPoint(x: 380, y: 220), CGPoint(x: 220, y: 360), CGPoint(x: 220, y: 222)
        ])
        let fitted = try #require(ShapeSnapper.fit(ink))
        // The corners it snapped to are the corners that were drawn.
        for corner in [CGPoint(x: 220, y: 220), CGPoint(x: 380, y: 220), CGPoint(x: 220, y: 360)] {
            let nearest = fitted.map { hypot($0.x - corner.x, $0.y - corner.y) }.min() ?? .infinity
            #expect(nearest < 6, "no snapped vertex near \(corner)")
        }
        // …and nothing is drawn in the empty bottom-right of the box.
        #expect(!fitted.contains { $0.x > 330 && $0.y > 310 })
    }

    @Test("A diamond, a pentagon and both hexagons each snap to themselves")
    func polygons() {
        let centre = CGPoint(x: 300, y: 300)
        let diamond = sketch(regular(4, centre: centre, radius: 70, start: -.pi / 2))
        #expect(ShapeSnapper.classify(diamond)?.shape == .polygon(sides: 4))
        // The pentagon fitted best and still lost to a 0.03 penalty, every time.
        let pentagon = sketch(regular(5, centre: centre, radius: 70, start: -.pi / 2))
        #expect(ShapeSnapper.classify(pentagon)?.shape == .polygon(sides: 5))
        let pointyTop = sketch(regular(6, centre: centre, radius: 70, start: -.pi / 2))
        #expect(ShapeSnapper.classify(pointyTop)?.shape == .polygon(sides: 6))
        let flatTop = sketch(regular(6, centre: centre, radius: 70, start: 0))
        #expect(ShapeSnapper.classify(flatTop)?.shape == .polygon(sides: 6, rotated: true))
        // And a circle is still a circle, not a polygon with many sides.
        let circle = sketch(regular(72, centre: centre, radius: 70, start: 0))
        #expect(ShapeSnapper.classify(circle)?.shape == .ellipse)
    }

    @Test("A tilted ellipse keeps its tilt instead of snapping upright")
    func tiltedEllipse() throws {
        let tilt: CGFloat = .pi / 180 * 35
        let upright = (0...72).map { index -> CGPoint in
            let t = CGFloat(index) / 72 * 2 * .pi
            return CGPoint(x: 90 * cos(t), y: 40 * sin(t))
        }
        let drawn = turned(upright, by: tilt, centre: CGPoint(x: 300, y: 300))
        let fit = try #require(ShapeSnapper.classify(sketch(drawn)))
        #expect(fit.shape == .ellipse)
        #expect(abs(fit.rotation - tilt) < .pi / 180 * 4, "fitted at \(fit.rotation * 180 / .pi)°")
        // The snapped outline follows the drawn one, not the upright ellipse in
        // its bounding box.
        let fitted = try #require(ShapeSnapper.fit(sketch(drawn)))
        #expect(ShapeSnapper.meanDistance(from: fitted, to: drawn) < 4)
    }

    @Test("A shape drawn a few degrees off level still snaps square to the page")
    func nearlyLevelStaysUpright() throws {
        let box: [CGPoint] = [
            CGPoint(x: -80, y: -40), CGPoint(x: 80, y: -40), CGPoint(x: 80, y: 40),
            CGPoint(x: -80, y: 40), CGPoint(x: -80, y: -39)
        ]
        let drawn = turned(box, by: .pi / 180 * 4, centre: CGPoint(x: 300, y: 300))
        let fit = try #require(ShapeSnapper.classify(sketch(drawn)))
        #expect(fit.shape == .rectangle)
        #expect(fit.rotation == 0)
    }

    @Test("A tilted shape resized under the pencil stays tilted")
    func tiltedLiveResize() throws {
        let tilt: CGFloat = .pi / 180 * 30
        let box: [CGPoint] = [
            CGPoint(x: -90, y: -35), CGPoint(x: 90, y: -35), CGPoint(x: 90, y: 35),
            CGPoint(x: -90, y: 35), CGPoint(x: -90, y: -33)
        ]
        let rectangle = turned(box, by: tilt, centre: CGPoint(x: 300, y: 300))
        let snap = try #require(ShapeSnapper.liveSnap(sketch(rectangle)))
        #expect(snap.shape == .rectangle)
        #expect(abs(snap.rotation - tilt) < .pi / 180 * 4)

        // Drag the handle further out along the shape's own long axis.
        let along = CGPoint(x: cos(snap.rotation) * 60, y: sin(snap.rotation) * 60)
        let path = try #require(ShapeSnapper.path(
            for: snap, handle: CGPoint(x: snap.handle.x + along.x, y: snap.handle.y + along.y)
        ))
        // Every side of the result still runs at the tilt (or square to it).
        let vertices = corners(of: path)
        #expect(vertices.count >= 4)
        guard vertices.count >= 2 else { return }
        let side = atan2(vertices[1].y - vertices[0].y, vertices[1].x - vertices[0].x)
        let quarter = CGFloat.pi / 2
        // Square to the snap's OWN axes — the shape is redrawn in the frame it
        // was fitted in, not re-fitted to the page.
        let offset = side - snap.rotation - ((side - snap.rotation) / quarter).rounded() * quarter
        #expect(abs(offset) < 0.01, "a side runs at \(side * 180 / .pi)°")
    }

    @Test("A drawn arc snaps to a clean arc, either way round")
    func arcs() throws {
        let centre = CGPoint(x: 300, y: 300)
        // Top half of a circle, drawn left to right.
        let half = (0...36).map { index -> CGPoint in
            let angle = CGFloat.pi + CGFloat(index) / 36 * .pi
            return CGPoint(x: centre.x + 80 * cos(angle), y: centre.y + 80 * sin(angle))
        }
        let snapped = try #require(ShapeSnapper.classify(sketch(half)))
        guard case .arc(let bulge) = snapped.shape else {
            Issue.record("a half circle came back as \(snapped.shape)")
            return
        }
        #expect(abs(abs(bulge) - 0.5) < 0.05, "a half circle bows half its width")
        let fitted = try #require(ShapeSnapper.fit(sketch(half)))
        #expect(ShapeSnapper.meanDistance(from: fitted, to: half) < 3)
        #expect(fitted.first == sketch(half).first, "it starts where the pencil started")

        // The same arc drawn right to left bows to the other side of its chord.
        let reversed = try #require(ShapeSnapper.fit(sketch(Array(half.reversed()))))
        #expect(ShapeSnapper.meanDistance(from: reversed, to: half) < 3)
    }

    @Test("A held arc is redrawn to the pencil without losing its bow")
    func liveArc() throws {
        let third = (0...24).map { index -> CGPoint in
            let angle = 0.3 + CGFloat(index) / 24 * 2.1
            return CGPoint(x: 300 + 100 * cos(angle), y: 300 + 100 * sin(angle))
        }
        let snap = try #require(ShapeSnapper.liveSnap(sketch(third)))
        guard case .arc(let bulge) = snap.shape else {
            Issue.record("expected an arc, got \(snap.shape)")
            return
        }
        let moved = CGPoint(x: snap.handle.x - 40, y: snap.handle.y + 10)
        let path = try #require(ShapeSnapper.path(for: snap, handle: moved))
        #expect(path.first == snap.anchor)
        #expect(hypot((path.last?.x ?? 0) - moved.x, (path.last?.y ?? 0) - moved.y) < 0.01)
        #expect(abs((ShapeSnapper.arcBulge(path) ?? 0) - bulge) < 0.02)
    }

    @Test("An L and a V snap to angles; an S curve snaps to nothing")
    func anglesAndCurves() {
        let l = sketch([CGPoint(x: 220, y: 200), CGPoint(x: 220, y: 360), CGPoint(x: 380, y: 360)])
        if case .angle(let bend)? = ShapeSnapper.classify(l)?.shape {
            #expect(hypot(bend.x - 220, bend.y - 360) < 8, "the bend is the drawn corner")
        } else {
            Issue.record("an L came back as \(String(describing: ShapeSnapper.classify(l)?.shape))")
        }
        let v = sketch([CGPoint(x: 200, y: 220), CGPoint(x: 290, y: 380), CGPoint(x: 380, y: 220)])
        if case .angle? = ShapeSnapper.classify(v)?.shape {} else { Issue.record("a V didn't snap to an angle") }

        let s = sketch((0...60).map { index in
            let t = CGFloat(index) / 60
            return CGPoint(x: 200 + 200 * t, y: 300 + 50 * sin(2 * .pi * t))
        })
        #expect(ShapeSnapper.classify(s) == nil, "an S is neither one bend nor one bow")
    }

}

/// The beautification pass end to end — everything except Vision, which is
/// injected. The pass was previously untestable (the recognizer was hardwired),
/// so nothing pinned the wiring between recognition, the plan, the canvas wipe and
/// the manifest write.
@MainActor
@Suite("Real-time beautification pass")
struct LiveBeautifierPassTests {
    private let pageSize = CGSize(width: 768, height: 1024)

    /// Mutable state the pass's @MainActor closures write into.
    @MainActor
    private final class Recorder {
        var drawing: PKDrawing
        var plans: [BeautifyPlan] = []
        var remaining: PKDrawing?
        var accepts = true

        init(_ drawing: PKDrawing) { self.drawing = drawing }
    }

    /// Three strokes sitting on one line, shaped like writing rather than a doodle.
    private func writingDrawing(y: CGFloat = 300) -> PKDrawing {
        let strokes = [0, 1, 2].map { index -> PKStroke in
            let x = 80 + CGFloat(index) * 90
            return stroke(line(
                from: CGPoint(x: x, y: y),
                to: CGPoint(x: x + 70, y: y + 28)
            ))
        }
        return PKDrawing(strokes: strokes)
    }

    private func run(
        _ beautifier: LiveBeautifier, _ recorder: Recorder,
        settings: BeautifySettings = BeautifySettings(isEnabled: true),
        pageID: UUID = UUID()
    ) async {
        await beautifier.runNow(
            pageID: pageID,
            settings: settings,
            fontName: "Helvetica",
            pageSize: pageSize,
            drawing: { recorder.drawing },
            apply: { plan, remaining in
                guard recorder.accepts else { return false }
                recorder.plans.append(plan)
                recorder.remaining = remaining
                recorder.drawing = remaining
                return true
            }
        )
    }

    @Test("A recognized line is typeset and its ink is wiped")
    func typesetsAndWipes() async {
        let recorder = Recorder(writingDrawing())
        let beautifier = LiveBeautifier(recognizer: { _, _ in [wholeCrop("hello world")] })

        await run(beautifier, recorder)

        #expect(recorder.plans.count == 1)
        let plan = recorder.plans.first
        #expect(plan?.inserts.count == 1)
        #expect(plan?.inserts.first?.text == "hello world")
        #expect(plan?.inserts.first?.kind == .text)
        #expect(plan?.inserts.first?.fontName == "Helvetica")
        // All three strokes were read, so all three come off the canvas.
        #expect(plan?.consumedStrokes == [0, 1, 2])
        #expect(recorder.remaining?.strokes.isEmpty == true)
    }

    @Test("Reading nothing back changes nothing, and says so")
    func emptyRecognitionIsANoOp() async {
        let recorder = Recorder(writingDrawing())
        let beautifier = LiveBeautifier(recognizer: { _, _ in [] })

        await run(beautifier, recorder)

        #expect(recorder.plans.isEmpty, "no text means no rewrite")
        #expect(recorder.drawing.strokes.count == 3, "the ink is left exactly as drawn")
        #expect(beautifier.lastPassFoundNothing, "a silent no-op is what 'nothing happens' looks like")
    }

    @Test("Writing on further down the same line appends to the run already typeset")
    func continuesAnExistingRun() async {
        let pageID = UUID()
        let recorder = Recorder(writingDrawing())
        let beautifier = LiveBeautifier(recognizer: { _, _ in [wholeCrop("hello")] })
        await run(beautifier, recorder, pageID: pageID)
        #expect(recorder.plans.first?.inserts.count == 1)

        // More writing, to the right of the first run and on the same line.
        recorder.drawing = PKDrawing(strokes: [
            stroke(line(from: CGPoint(x: 380, y: 300), to: CGPoint(x: 450, y: 328)))
        ])
        await run(beautifier, recorder, pageID: pageID)

        let second = recorder.plans.last
        #expect(second?.inserts.isEmpty == true, "it joins the line instead of stacking a box")
        #expect(second?.updates.count == 1)
        #expect(second?.updates.first?.text == "hello hello")
        #expect(second?.updates.first?.id == recorder.plans.first?.inserts.first?.id)
    }

    @Test("A refused pass leaves the run list alone so the next one re-inserts")
    func refusedPassDoesNotRememberRuns() async {
        let pageID = UUID()
        let recorder = Recorder(writingDrawing())
        recorder.accepts = false
        let beautifier = LiveBeautifier(recognizer: { _, _ in [wholeCrop("hello")] })
        await run(beautifier, recorder, pageID: pageID)
        #expect(recorder.plans.isEmpty)

        // The pencil came back down and the canvas refused the swap; the ink is
        // still there, so the retry must INSERT — appending to a text box that was
        // never created would silently drop the line.
        recorder.accepts = true
        await run(beautifier, recorder, pageID: pageID)
        #expect(recorder.plans.last?.inserts.count == 1)
        #expect(recorder.plans.last?.updates.isEmpty == true)
    }

    @Test("A doodle is not writing, and is never eaten")
    func leavesDiagramsAlone() async {
        // 180 pt of ink in one stroke — far taller than any line of handwriting,
        // so even a recognizer that confidently reads words out of it is ignored.
        // Vision always returns its best guess; the height guard is what stops
        // that guess from replacing somebody's diagram with a sentence.
        let recorder = Recorder(PKDrawing(strokes: [
            stroke(line(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 210, y: 380)))
        ]))
        let beautifier = LiveBeautifier(recognizer: { _, _ in [wholeCrop("this is a diagram, not writing")] })

        await run(beautifier, recorder)

        #expect(recorder.plans.isEmpty)
        #expect(recorder.drawing.strokes.count == 1)
    }

    @Test("Writing at the page's own size is read, not thrown away for being big")
    func acceptsWritingAtPageScale() async {
        // The bug this pins. Zooming in lays the page out bigger WITHOUT changing
        // its logical size, so the same hand covers fewer logical points — and
        // only then did a line fit under the old flat 130-point ceiling. At the
        // page's natural size a comfortable hand is well over it, so every line
        // was read perfectly and then discarded: "it only works zoomed in".
        let tall = stroke(line(
            from: CGPoint(x: 90, y: 300), to: CGPoint(x: 520, y: 460)
        ))
        let recorder = Recorder(PKDrawing(strokes: [tall]))
        let beautifier = LiveBeautifier(recognizer: { _, _ in [wholeCrop("big handwriting")] })

        #expect(tall.renderBounds.height > LiveBeautifier.maximumLineHeight)
        #expect(LiveBeautifier.isWritingLine(tall.renderBounds, pageSize: pageSize))

        await run(beautifier, recorder)
        #expect(recorder.plans.count == 1, "a line written at page scale is still a line")
    }

    @Test("The language the panel is set to is the one Vision is asked for")
    func passesTheChosenLanguage() async {
        let recorder = Recorder(writingDrawing())
        let asked = LanguageBox()
        let beautifier = LiveBeautifier(recognizer: { _, language in
            await asked.record(language)
            return [wholeCrop("bonjour")]
        })

        await run(
            beautifier, recorder,
            settings: BeautifySettings(isEnabled: true, language: "fr-FR")
        )

        #expect(await asked.value == "fr-FR")
    }

    @Test("A recognized line is run through the corrector before it's typeset")
    func correctsTheRecognizedText() async {
        let recorder = Recorder(writingDrawing())
        let beautifier = LiveBeautifier(
            recognizer: { _, _ in [wholeCrop("bautiful")] },
            corrector: { candidates, _ in candidates.first == "bautiful" ? "beautiful" : candidates.first ?? "" }
        )

        await run(beautifier, recorder)

        #expect(recorder.plans.first?.inserts.first?.text == "beautiful")
    }

    @Test("Vision's alternate readings for a line reach the corrector, top guess first")
    func passesAlternatesToTheCorrector() async {
        let recorder = Recorder(writingDrawing())
        let beautifier = LiveBeautifier(
            recognizer: { _, _ in
                [OCRService.Line(
                    text: "bautiful", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                    confidence: 0.9, alternates: ["beautiful", "bountiful"]
                )]
            },
            // A stand-in for the real dictionary-scoring corrector: picks
            // whichever candidate is already a real word.
            corrector: { candidates, _ in candidates.first { $0 == "beautiful" } ?? candidates[0] }
        )

        await run(beautifier, recorder)

        #expect(recorder.plans.first?.inserts.first?.text == "beautiful")
    }
}

/// A stub reading that fills the whole crop it was given, which is what a
/// recognizer that read everything on the page would hand back.
private func wholeCrop(_ text: String) -> OCRService.Line {
    OCRService.Line(
        text: text,
        boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
        confidence: 0.9
    )
}

/// Somewhere for the (nonisolated, Sendable) recognizer stub to leave what it saw.
private actor LanguageBox {
    var value: String?
    func record(_ language: String) { value = language }
}

/// The half of the pass the stubs deliberately skip: does Vision actually read
/// back the image we hand it? Everything upstream of this can be correct and the
/// feature still does nothing on the page, which is exactly how it failed.
@MainActor
@Suite("Beautification reads real ink")
struct LiveBeautifierRecognitionTests {
    private let pageSize = CGSize(width: 768, height: 1024)

    /// Block capitals drawn as strokes — the closest thing to handwriting that can
    /// be written down deterministically in a test.
    private func letters() -> PKDrawing {
        func segment(_ a: CGPoint, _ b: CGPoint) -> PKStroke {
            let controls = [a, b].enumerated().map { index, point in
                PKStrokePoint(
                    location: point, timeOffset: TimeInterval(index) * 0.05,
                    size: CGSize(width: 7, height: 7), opacity: 1,
                    force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            return PKStroke(
                ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: controls, creationDate: Date())
            )
        }

        let top: CGFloat = 300, bottom: CGFloat = 366
        var strokes: [PKStroke] = []
        var x: CGFloat = 100
        let width: CGFloat = 44, gap: CGFloat = 26

        // H
        strokes.append(segment(CGPoint(x: x, y: top), CGPoint(x: x, y: bottom)))
        strokes.append(segment(CGPoint(x: x + width, y: top), CGPoint(x: x + width, y: bottom)))
        strokes.append(segment(
            CGPoint(x: x, y: (top + bottom) / 2), CGPoint(x: x + width, y: (top + bottom) / 2)
        ))
        x += width + gap
        // I
        strokes.append(segment(CGPoint(x: x, y: top), CGPoint(x: x, y: bottom)))
        x += gap + gap
        // T
        strokes.append(segment(CGPoint(x: x, y: top), CGPoint(x: x + width, y: top)))
        strokes.append(segment(CGPoint(x: x + width / 2, y: top), CGPoint(x: x + width / 2, y: bottom)))
        return PKDrawing(strokes: strokes)
    }

    @Test("Vision reads the black-on-white crop the pass renders")
    func visionReadsTheRender() async throws {
        let drawing = letters()
        let bounds = drawing.bounds
        #expect(LiveBeautifier.looksLikeWriting(bounds), "the sample has to look like a line first")

        let padding = max(10, bounds.height * 0.35)
        let region = bounds.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: pageSize))
        let image = LiveBeautifier.recognitionImage(
            of: drawing, region: region,
            scale: LiveBeautifier.renderScale(for: bounds, in: region)
        )

        let text = try await OCRService().recognizeText(in: image, languages: ["en-US"])
        // Not an exact-match assertion: recognition is a model, and pinning it to
        // one string would make this a test of Vision's build rather than of ours.
        // Reading SOMETHING back is the thing that was in doubt.
        #expect(!text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty,
                "Vision read nothing from the pass's own render — that is the feature doing nothing")
    }

    @Test("The full pass, with the shipping recognizer, typesets what it reads")
    func fullPassWithVision() async {
        final class Box {
            var drawing: PKDrawing
            var plan: BeautifyPlan?
            init(_ drawing: PKDrawing) { self.drawing = drawing }
        }
        let box = Box(letters())
        let beautifier = LiveBeautifier()

        await beautifier.runNow(
            pageID: UUID(),
            settings: BeautifySettings(isEnabled: true),
            fontName: "Helvetica",
            pageSize: pageSize,
            drawing: { box.drawing },
            apply: { plan, remaining in
                box.plan = plan
                box.drawing = remaining
                return true
            }
        )

        #expect(box.plan != nil, "the shipping path produced no plan at all")
        #expect(box.plan?.inserts.isEmpty == false)
        #expect(box.drawing.strokes.isEmpty, "the ink it read is wiped")
    }
}

/// The system spell checker beautification runs its output through — on-device,
/// no network, no per-use cost.
@MainActor
@Suite("Spell correction")
struct SpellCorrectorTests {
    @Test("A misspelled word is replaced with the checker's top guess")
    func fixesAnObviousTypo() {
        #expect(SpellCorrector.correct("bautiful", language: "en-US") == "beautiful")
    }

    @Test("Correction fixes a word inside a longer line, leaving the rest untouched")
    func fixesInsideASentence() {
        let corrected = SpellCorrector.correct("what a bautiful day", language: "en-US")
        #expect(corrected == "what a beautiful day")
    }

    @Test("A correctly spelled sentence is returned unchanged")
    func leavesCorrectTextAlone() {
        #expect(SpellCorrector.correct("hello world", language: "en-US") == "hello world")
    }

    @Test("A capitalized sentence-starter keeps its capitalization when corrected")
    func preservesLeadingCapitalization() {
        let corrected = SpellCorrector.correct("Bautiful day today", language: "en-US")
        #expect(corrected.hasPrefix("Beautiful"))
    }

    @Test("An empty string round-trips without touching the checker")
    func emptyStringIsANoOp() {
        #expect(SpellCorrector.correct("", language: "en-US") == "")
    }

    @Test("matchCase mirrors lowercase, capitalized and stranger casing")
    func matchCase() {
        #expect(SpellCorrector.matchCase(of: "bautiful", to: "beautiful") == "beautiful")
        #expect(SpellCorrector.matchCase(of: "Bautiful", to: "beautiful") == "Beautiful")
        #expect(SpellCorrector.matchCase(of: "bAUTIFUL", to: "beautiful") == "beautiful")
    }

    @Test("A clean word scores zero misspellings, a mangled one scores at least one")
    func misspellingCountScoresPlausibility() {
        #expect(SpellCorrector.misspellingCount(in: "beautiful day", language: "en-US") == 0)
        #expect(SpellCorrector.misspellingCount(in: "bautfl day", language: "en-US") >= 1)
    }

    @Test("Given Vision's top guess and its runners-up, the more plausible one wins")
    func bestOfPicksTheDictionaryWord() {
        // Vision's top candidate reads as confident nonsense; a runner-up is the
        // real word — this is what a misread letter looks like in practice.
        let corrected = SpellCorrector.correct(bestOf: ["bautfl", "beautiful", "bountiful"], language: "en-US")
        #expect(corrected == "beautiful")
    }

    @Test("A tie between equally plausible candidates keeps Vision's own top guess")
    func bestOfKeepsRankingOnTies() {
        let corrected = SpellCorrector.correct(bestOf: ["hello", "hellp"], language: "en-US")
        #expect(corrected == "hello")
    }

    @Test("An empty candidate list returns an empty string rather than trapping")
    func bestOfHandlesNoCandidates() {
        #expect(SpellCorrector.correct(bestOf: [], language: "en-US") == "")
    }
}
