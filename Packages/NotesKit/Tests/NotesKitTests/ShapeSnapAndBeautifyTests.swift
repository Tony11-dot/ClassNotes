import CoreGraphics
import Foundation
import NotesModels
import NotesServices
import PencilKit
import Testing
import UIKit
@testable import NotesEditor

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

    @Test("An open stroke that is neither straight nor a single bend is left alone")
    func leavesFreehandAlone() {
        // A squiggle: three reversals, no clean primitive in it.
        let squiggle = (0...60).map { index -> CGPoint in
            let t = CGFloat(index) / 60
            return CGPoint(x: 100 + t * 300, y: 300 + sin(t * .pi * 6) * 60)
        }
        #expect(ShapeSnapper.fit(squiggle) == nil)
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
        let beautifier = LiveBeautifier(recognizer: { _, _ in "hello world" })

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
        let beautifier = LiveBeautifier(recognizer: { _, _ in "" })

        await run(beautifier, recorder)

        #expect(recorder.plans.isEmpty, "no text means no rewrite")
        #expect(recorder.drawing.strokes.count == 3, "the ink is left exactly as drawn")
        #expect(beautifier.lastPassFoundNothing, "a silent no-op is what 'nothing happens' looks like")
    }

    @Test("Writing on further down the same line appends to the run already typeset")
    func continuesAnExistingRun() async {
        let pageID = UUID()
        let recorder = Recorder(writingDrawing())
        let beautifier = LiveBeautifier(recognizer: { _, _ in "hello" })
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
        let beautifier = LiveBeautifier(recognizer: { _, _ in "hello" })
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
        // Tall and narrow: fails `looksLikeWriting`, so it never reaches Vision.
        let recorder = Recorder(PKDrawing(strokes: [
            stroke(line(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 210, y: 380)))
        ]))
        let beautifier = LiveBeautifier(recognizer: { _, _ in "should never be asked" })

        await run(beautifier, recorder)

        #expect(recorder.plans.isEmpty)
        #expect(recorder.drawing.strokes.count == 1)
    }

    @Test("The language the panel is set to is the one Vision is asked for")
    func passesTheChosenLanguage() async {
        let recorder = Recorder(writingDrawing())
        let asked = LanguageBox()
        let beautifier = LiveBeautifier(recognizer: { _, language in
            await asked.record(language)
            return "bonjour"
        })

        await run(
            beautifier, recorder,
            settings: BeautifySettings(isEnabled: true, language: "fr-FR")
        )

        #expect(await asked.value == "fr-FR")
    }
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
            of: drawing, region: region, scale: LiveBeautifier.renderScale(for: bounds)
        )

        let text = try await OCRService().recognizeText(in: image, languages: ["en-US"])
        // Not an exact-match assertion: recognition is a model, and pinning it to
        // one string would make this a test of Vision's build rather than of ours.
        // Reading SOMETHING back is the thing that was in doubt.
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
