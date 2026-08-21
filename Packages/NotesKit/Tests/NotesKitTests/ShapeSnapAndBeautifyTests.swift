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
        points.append((CGPoint(x: 300, y: 100), 1.1))

        #expect(ShapeSnapper.holdDuration(of: stroke(points)) >= 0.6)
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
        points.append((CGPoint(x: 340, y: 200), 1.3))

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
        points.append((CGPoint(x: 280, y: 401), 0.75))

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
            corrector: { text, _ in text == "bautiful" ? "beautiful" : text }
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
}
