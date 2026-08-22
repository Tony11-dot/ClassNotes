import CoreGraphics
import Foundation
import NotesModels
import PencilKit
import Testing
@testable import NotesEditor

@Suite("Stroke smoothing")
struct StrokeSmoothingTests {
    @Test("A window of 1 is the identity — the pencil's own path is untouched")
    func identityAtWindowOne() {
        let points = (0..<20).map { CGPoint(x: Double($0), y: Double($0 % 3)) }
        #expect(StrokeSmoothing.smooth(points, window: 1) == points)
    }

    @Test("A wider window shrinks tremor but keeps the endpoints pinned")
    func smoothingReducesJitter() {
        // A straight line with alternating ±4 pt jitter on top of it.
        let points = (0..<40).map { index in
            CGPoint(x: Double(index) * 5, y: index % 2 == 0 ? 4 : -4)
        }
        let smoothed = StrokeSmoothing.smooth(points, window: 11)

        #expect(smoothed.first == points.first, "the stroke still starts where the pencil landed")
        #expect(smoothed.last == points.last, "and ends where it lifted")
        #expect(smoothed.count == points.count)

        let before = deviation(points)
        let after = deviation(smoothed)
        #expect(after < before / 2, "expected the jitter to more than halve, got \(after) from \(before)")
    }

    @Test("Paths too short to average are returned unchanged")
    func shortPaths() {
        let two = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        #expect(StrokeSmoothing.smooth(two, window: 13) == two)
        #expect(StrokeSmoothing.smooth([], window: 13).isEmpty)
    }

    /// Mean absolute distance of the interior points from the y = 0 axis.
    private func deviation(_ points: [CGPoint]) -> Double {
        let interior = points.dropFirst().dropLast()
        guard !interior.isEmpty else { return 0 }
        return interior.reduce(0) { $0 + abs(Double($1.y)) } / Double(interior.count)
    }
}

@Suite("Scribble to erase")
struct ScribbleDetectorTests {
    /// A back-and-forth scrub: five sweeps across a 100 × 40 pt band, the way you
    /// actually scrub a word out.
    private var scrub: [CGPoint] {
        var points: [CGPoint] = []
        for sweep in 0..<5 {
            let forward = sweep % 2 == 0
            for step in 0...10 {
                let t = Double(forward ? step : 10 - step) / 10
                points.append(CGPoint(x: t * 100, y: 20 + Double(sweep) * 10))
            }
        }
        return points
    }

    @Test("A scrub back and forth reads as an erase gesture")
    func detectsScrub() {
        #expect(ScribbleDetector.isErasureScribble(scrub))
    }

    @Test("Ordinary handwriting is never mistaken for a scrub")
    func rejectsWriting() {
        // A straight line.
        let line = (0...30).map { CGPoint(x: Double($0) * 4, y: 0) }
        #expect(!ScribbleDetector.isErasureScribble(line))

        // A lowercase 'm' — three humps, no folding back over itself.
        var letter: [CGPoint] = []
        for step in 0...36 {
            let t = Double(step) / 36
            letter.append(CGPoint(x: t * 40, y: -abs(sin(t * 3 * .pi)) * 20))
        }
        #expect(!ScribbleDetector.isErasureScribble(letter))

        // A big circle: plenty of direction change, but it doesn't fold back.
        let circle = (0...48).map { step -> CGPoint in
            let angle = Double(step) / 48 * 2 * .pi
            return CGPoint(x: cos(angle) * 60, y: sin(angle) * 60)
        }
        #expect(!ScribbleDetector.isErasureScribble(circle))
    }

    @Test("A tap or a tiny mark is never an erase gesture")
    func rejectsTinyMarks() {
        #expect(!ScribbleDetector.isErasureScribble([CGPoint(x: 5, y: 5)]))
        let dot = (0..<12).map { CGPoint(x: Double($0 % 3), y: Double($0 % 2)) }
        #expect(!ScribbleDetector.isErasureScribble(dot))
    }

    @Test("Crossing is decided by proximity, within tolerance")
    func crossing() {
        let horizontal = (0...20).map { CGPoint(x: Double($0) * 5, y: 50) }
        let through = (0...20).map { CGPoint(x: 50, y: Double($0) * 5) }
        let elsewhere = (0...20).map { CGPoint(x: 400 + Double($0), y: 400) }

        #expect(ScribbleDetector.crosses(horizontal, through, tolerance: 6))
        #expect(!ScribbleDetector.crosses(horizontal, elsewhere, tolerance: 6))
    }

    @Test("Scribble-erase removes the crossed strokes and the scribble itself")
    func erasesCrossedStrokes() throws {
        let target = stroke(from: (0...10).map { CGPoint(x: Double($0) * 10, y: 40) })
        let bystander = stroke(from: (0...10).map { CGPoint(x: Double($0) * 10, y: 400) })
        let drawing = PKDrawing(strokes: [target, bystander, stroke(from: scrub)])

        let cleaned = try #require(ScribbleEraser.applying(to: drawing))
        #expect(cleaned.strokes.count == 1, "only the far-away stroke survives")
        #expect(cleaned.strokes[0].renderBounds.midY > 300)
    }

    @Test("A normal stroke leaves the drawing alone")
    func leavesNormalStrokesAlone() {
        let line = stroke(from: (0...20).map { CGPoint(x: Double($0) * 6, y: 20) })
        let drawing = PKDrawing(strokes: [line])
        #expect(ScribbleEraser.applying(to: drawing) == nil)
    }

    @Test("A scrub over blank paper stays on the page")
    func scrubOverNothingIsKept() {
        // Writing fast — a "www", a hatch, a zigzag arrow — reads as a scrub. If
        // that swallowed the stroke, the letters would appear and vanish a moment
        // later. An erase that erases nothing is not an erase.
        let drawing = PKDrawing(strokes: [stroke(from: scrub)])
        #expect(ScribbleEraser.applying(to: drawing) == nil)
    }

    @Test("A scrub next to ink it never crosses keeps both")
    func scrubMissingInkKeepsBoth() {
        let faraway = stroke(from: (0...10).map { CGPoint(x: Double($0) * 10, y: 600) })
        let drawing = PKDrawing(strokes: [faraway, stroke(from: scrub)])
        #expect(ScribbleEraser.applying(to: drawing) == nil)
    }

    private func stroke(from points: [CGPoint]) -> PKStroke {
        let controlPoints = points.enumerated().map { index, location in
            PKStrokePoint(
                location: location, timeOffset: Double(index) * 0.01,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSince1970: 0))
        )
    }
}

@Suite("Line grouping")
struct LineGrouperTests
{
    @Test("Words on the same line group together, left to right")
    func groupsWords() {
        let boxes = [
            CGRect(x: 200, y: 100, width: 40, height: 20),   // "world" (2nd)
            CGRect(x: 100, y: 102, width: 60, height: 18),   // "hello" (1st)
            CGRect(x: 100, y: 200, width: 50, height: 20)    // next line
        ]
        let lines = LineGrouper.lines(of: boxes)
        #expect(lines.count == 2)
        #expect(lines[0] == [1, 0], "the first line reads left to right")
        #expect(lines[1] == [2])
    }

    @Test("Lines come back top to bottom whatever order they were drawn in")
    func ordersLines() {
        let boxes = [
            CGRect(x: 10, y: 300, width: 40, height: 20),
            CGRect(x: 10, y: 20, width: 40, height: 20),
            CGRect(x: 10, y: 160, width: 40, height: 20)
        ]
        #expect(LineGrouper.lines(of: boxes) == [[1], [2], [0]])
    }

    @Test("A tall ascender still belongs to its line")
    func toleratesAscenders() {
        let boxes = [
            CGRect(x: 10, y: 100, width: 30, height: 20),    // 'o'
            CGRect(x: 44, y: 88, width: 12, height: 34)      // 'l' — taller
        ]
        #expect(LineGrouper.lines(of: boxes) == [[0, 1]])
    }

    @Test("Empty and degenerate boxes are dropped")
    func skipsEmpty() {
        let boxes = [CGRect.null, CGRect(x: 0, y: 0, width: 10, height: 0),
                     CGRect(x: 0, y: 50, width: 10, height: 10)]
        #expect(LineGrouper.lines(of: boxes) == [[2]])
        #expect(LineGrouper.lines(of: []).isEmpty)
    }
}

@Suite("Beautified text layout")
struct BeautifyLayoutTests {
    private let pageSize = PageSize.a4.portraitSize

    /// A face that measures 10 pt per character per point of type size, so the
    /// arithmetic in a test is something you can do in your head.
    private let metrics = TextMetrics(
        width: { text, size in Double(text.count) * size * 0.5 },
        lineHeight: { size in size * 1.2 }
    )

    @Test("Typeset text lands on the handwriting's own line")
    func framesOnBaseline() {
        let ink = CGRect(x: 90, y: 200, width: 300, height: 34)
        let frame = BeautifyLayout.frame(
            inkBounds: ink, text: "twenty-two characters", typeSize: 24,
            lineSpacing: 1.2, metrics: metrics, in: pageSize
        )
        #expect(abs(frame.minX - ink.minX) < 1, "it starts where the writing started")
        #expect(abs(frame.midY - ink.midY) < 2, "and sits on the same line")
        #expect(frame.height >= 24)
    }

    @Test("The box is as tall as the type size and line spacing ask for")
    func heightFollowsTheSettings() {
        let ink = CGRect(x: 40, y: 300, width: 200, height: 30)
        func height(size: Double, spacing: Double) -> Double {
            BeautifyLayout.frame(
                inkBounds: ink, text: "one line", typeSize: size,
                lineSpacing: spacing, metrics: metrics, in: pageSize
            ).height
        }
        // One line at 24 pt, 1.0 spacing: lineHeight(24) + 6 pt padding each side.
        #expect(abs(height(size: 24, spacing: 1) - (24 * 1.2 + 12)) < 0.01)
        // Doubling the spacing doubles the leading, and nothing else.
        #expect(abs(height(size: 24, spacing: 2) - (24 * 1.2 * 2 + 12)) < 0.01)
        // A bigger size is a taller box at the same spacing.
        #expect(height(size: 40, spacing: 1) > height(size: 24, spacing: 1))
    }

    @Test("Text too long for one line gets a box tall enough for the wraps")
    func wrappedTextGetsRoom() {
        let ink = CGRect(x: 40, y: 300, width: 200, height: 26)
        let single = BeautifyLayout.frame(
            inkBounds: ink, text: "short", typeSize: 24,
            lineSpacing: 1, metrics: metrics, in: pageSize
        )
        // 300 characters at 12 pt each is far wider than any page.
        let wrapped = BeautifyLayout.frame(
            inkBounds: ink, text: String(repeating: "a", count: 300), typeSize: 24,
            lineSpacing: 1, metrics: metrics, in: pageSize
        )
        #expect(wrapped.maxX <= pageSize.width + 0.01, "it still fits the page")
        #expect(wrapped.height > single.height * 2, "so the extra lines have somewhere to go")
    }

    @Test("Frames stay on the page, however near the edge the writing was")
    func clampsToPage() {
        let edge = CGRect(x: pageSize.width - 20, y: pageSize.height - 10, width: 300, height: 30)
        let frame = BeautifyLayout.frame(
            inkBounds: edge, text: String(repeating: "x", count: 40), typeSize: 22,
            lineSpacing: 1.2, metrics: metrics, in: pageSize
        )
        #expect(frame.minX >= 0)
        #expect(frame.maxX <= pageSize.width + 0.01)
        #expect(frame.maxY <= pageSize.height + 0.01)
    }

    @Test("Longer text gets a wider box")
    func widthTracksLength() {
        let ink = CGRect(x: 40, y: 100, width: 60, height: 24)
        let short = BeautifyLayout.frame(
            inkBounds: ink, text: "abcd", typeSize: 20,
            lineSpacing: 1.2, metrics: metrics, in: pageSize
        )
        let long = BeautifyLayout.frame(
            inkBounds: ink, text: String(repeating: "a", count: 30), typeSize: 20,
            lineSpacing: 1.2, metrics: metrics, in: pageSize
        )
        #expect(long.width > short.width)
    }

    @Test("Writing on further along the same line continues the existing run")
    func continuesRun() {
        let run = CGRect(x: 60, y: 200, width: 180, height: 30)
        let sameLine = CGRect(x: 250, y: 202, width: 90, height: 28)
        let nextLine = CGRect(x: 60, y: 260, width: 90, height: 28)
        let farRight = CGRect(x: 560, y: 201, width: 40, height: 28)

        #expect(BeautifyLayout.continues(existing: run, incoming: sameLine, typeSize: 22))
        #expect(!BeautifyLayout.continues(existing: run, incoming: nextLine, typeSize: 22))
        #expect(!BeautifyLayout.continues(existing: run, incoming: farRight, typeSize: 22))
    }

    @Test("Merging keeps the run's start and line, and widens it to fit the words")
    func mergeKeepsBaseline() {
        let run = CGRect(x: 60, y: 200, width: 180, height: 30)
        let more = CGRect(x: 250, y: 202, width: 90, height: 28)
        let merged = BeautifyLayout.merged(
            existing: run, incoming: more, text: "hi my name is tony",
            typeSize: 24, lineSpacing: 1, metrics: metrics, in: pageSize
        )
        #expect(merged.minX == run.minX)
        #expect(merged.minY == run.minY)
        #expect(merged.width > run.width)
        // The box holds the JOINED text — the union of the two boxes is only a
        // lower bound, and trusting it is what clipped a growing line.
        #expect(merged.width >= metrics.width("hi my name is tony", 24))
    }
}

@MainActor
@Suite("Real-time beautification planning")
struct LiveBeautifierPlanTests {
    private let pageSize = PageSize.a4.portraitSize
    /// A face whose measurements are easy to reason about in a test.
    private let metrics = TextMetrics(
        width: { text, size in Double(text.count) * size * 0.5 },
        lineHeight: { size in size * 1.2 }
    )

    private func line(
        _ text: String, at rect: CGRect, strokes: [Int], force: Double = 0.2
    ) -> RecognizedLine {
        RecognizedLine(text: text, bounds: rect, strokeIndices: strokes, meanForce: force)
    }

    @Test("Each recognized line becomes one typeset run in the chosen font")
    func insertsRuns() {
        let plan = LiveBeautifier.plan(
            lines: [
                line("hi my name is", at: CGRect(x: 80, y: 120, width: 320, height: 40), strokes: [0, 1, 2]),
                line("tony", at: CGRect(x: 80, y: 200, width: 90, height: 38), strokes: [3])
            ],
            existing: [],
            settings: BeautifySettings(isEnabled: true, unifySizeAndSpacing: true, fontSize: 23),
            fontName: "SnellRoundhand",
            colorHex: nil,
            pageSize: pageSize,
            metrics: { _ in metrics }
        )
        #expect(plan.inserts.count == 2)
        #expect(plan.updates.isEmpty)
        #expect(plan.inserts.allSatisfy { $0.fontName == "SnellRoundhand" })
        #expect(plan.inserts.allSatisfy { $0.kind == .text })
        #expect(plan.inserts.allSatisfy { $0.resolvedFontSize == 23 })
        #expect(plan.consumedStrokes == [0, 1, 2, 3], "every read stroke is wiped")
        #expect(plan.runs.count == 2)
    }

    @Test("Unify off tracks the size of the handwriting itself")
    func honorsHandwritingSize() {
        let settings = BeautifySettings(isEnabled: true, unifySizeAndSpacing: false)
        let plan = LiveBeautifier.plan(
            lines: [
                line("small", at: CGRect(x: 40, y: 40, width: 80, height: 18), strokes: [0]),
                line("BIG", at: CGRect(x: 40, y: 140, width: 200, height: 60), strokes: [1])
            ],
            existing: [], settings: settings, fontName: "Georgia",
            colorHex: nil, pageSize: pageSize, metrics: { _ in metrics }
        )
        let sizes = plan.inserts.map(\.resolvedFontSize)
        #expect(sizes.count == 2)
        #expect(sizes[0] < sizes[1], "the bigger writing is set bigger: \(sizes)")
    }

    @Test("Writing on further along a line appends to the run already there")
    func appendsToRun() throws {
        let existingID = UUID()
        let runFrame = CGRect(x: 80, y: 118, width: 300, height: 34)
        let plan = LiveBeautifier.plan(
            lines: [line("is tony", at: CGRect(x: 390, y: 120, width: 120, height: 32), strokes: [4, 5])],
            existing: [BeautifiedRun(elementID: existingID, frame: runFrame, text: "hi my name")],
            settings: BeautifySettings(isEnabled: true),
            fontName: "Georgia", colorHex: nil, pageSize: pageSize, metrics: { _ in metrics }
        )
        #expect(plan.inserts.isEmpty)
        let updated = try #require(plan.updates.first)
        #expect(updated.id == existingID)
        #expect(updated.text == "hi my name is tony")
        #expect(updated.width >= runFrame.width)
        #expect(plan.runs.count == 1)
    }

    @Test("A new line below starts its own run")
    func newLineStartsNewRun() {
        let plan = LiveBeautifier.plan(
            lines: [line("second line", at: CGRect(x: 80, y: 220, width: 200, height: 30), strokes: [9])],
            existing: [BeautifiedRun(
                elementID: UUID(),
                frame: CGRect(x: 80, y: 118, width: 300, height: 34),
                text: "first line"
            )],
            settings: BeautifySettings(isEnabled: true),
            fontName: "Georgia", colorHex: nil, pageSize: pageSize, metrics: { _ in metrics }
        )
        #expect(plan.inserts.count == 1)
        #expect(plan.updates.isEmpty)
        #expect(plan.runs.count == 2)
    }

    @Test("Dynamic Bold only fires when the pen was actually pressed hard")
    func dynamicBold() {
        func plan(force: Double, dynamicBold: Bool) -> BeautifyPlan {
            LiveBeautifier.plan(
                lines: [line("pressed", at: CGRect(x: 40, y: 40, width: 120, height: 30),
                             strokes: [0], force: force)],
                existing: [],
                settings: BeautifySettings(isEnabled: true, dynamicBold: dynamicBold),
                fontName: "Georgia", colorHex: nil, pageSize: pageSize, metrics: { _ in metrics }
            )
        }
        #expect(plan(force: 0.9, dynamicBold: true).inserts[0].isBold)
        #expect(!plan(force: 0.1, dynamicBold: true).inserts[0].isBold)
        #expect(!plan(force: 0.9, dynamicBold: false).inserts[0].isBold)
    }

    @Test("Nothing recognized means nothing changes and no ink is lost")
    func emptyPlan() {
        let plan = LiveBeautifier.plan(
            lines: [], existing: [], settings: BeautifySettings(isEnabled: true),
            fontName: "Georgia", colorHex: nil, pageSize: pageSize, metrics: { _ in metrics }
        )
        #expect(plan.isEmpty)
        #expect(plan.consumedStrokes.isEmpty)
    }

    @Test("Only line-shaped ink is beautified — diagrams and doodles are left alone")
    func writingHeuristic() {
        #expect(LiveBeautifier.looksLikeWriting(CGRect(x: 0, y: 0, width: 300, height: 32)))
        // A hairline (a rule someone drew), a tall block (a diagram), and a
        // vertical mark all stay as ink.
        #expect(!LiveBeautifier.looksLikeWriting(CGRect(x: 0, y: 0, width: 300, height: 3)))
        #expect(!LiveBeautifier.looksLikeWriting(CGRect(x: 0, y: 0, width: 300, height: 400)))
        #expect(!LiveBeautifier.looksLikeWriting(CGRect(x: 0, y: 0, width: 10, height: 90)))
        #expect(!LiveBeautifier.looksLikeWriting(.null))
    }

    @Test("Recognition scale rises for small writing and falls for large")
    func renderScale() {
        let smallInk = CGRect(x: 0, y: 0, width: 100, height: 14)
        let largeInk = CGRect(x: 0, y: 0, width: 400, height: 110)
        let small = LiveBeautifier.renderScale(for: smallInk, in: smallInk.insetBy(dx: -12, dy: -12))
        let large = LiveBeautifier.renderScale(for: largeInk, in: largeInk.insetBy(dx: -12, dy: -12))
        #expect(small > large)
        #expect(small <= 10)
        #expect(large >= 1)
    }

    @Test("The recognition image is black ink on an opaque white page")
    func recognitionImageIsHighContrast() throws {
        // Vision reads dark-on-light. PKDrawing renders the ink in its OWN colour on
        // a TRANSPARENT background, so light ink (dark theme) or a flattened alpha
        // gave Vision nothing to read and no line was ever typeset. Whatever colour
        // the pen was, the image handed to Vision must be black on white.
        let points = (0...40).map { index in
            PKStrokePoint(
                location: CGPoint(x: 10 + Double(index) * 4, y: 20),
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: 6, height: 6), opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2
            )
        }
        // White ink, as a dark theme would write with.
        let stroke = PKStroke(
            ink: PKInk(.pen, color: .white),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        )
        let region = CGRect(x: 0, y: 0, width: 200, height: 40)
        let image = LiveBeautifier.recognitionImage(
            of: PKDrawing(strokes: [stroke]), region: region, scale: 2
        )
        let cgImage = try #require(image.cgImage)
        #expect(cgImage.width == 400 && cgImage.height == 80, "the crop keeps its scale")

        let samples = try #require(Self.samples(of: cgImage))
        // A corner is bare page…
        #expect(samples.corner.alpha == 255, "the page must be opaque, not transparent")
        #expect(samples.corner.luminance > 240, "the page must be white")
        // …and the middle of the line is ink.
        #expect(samples.centre.luminance < 80, "the ink must come out dark, got \(samples.centre.luminance)")
    }

    private struct Pixel { let luminance: Int; let alpha: Int }

    /// Top-left and centre pixels of `image`, as luminance + alpha.
    private static func samples(of image: CGImage) -> (corner: Pixel, centre: Pixel)? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func pixel(x: Int, y: Int) -> Pixel {
            let offset = (y * width + x) * 4
            let luminance = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
            return Pixel(luminance: luminance, alpha: Int(bytes[offset + 3]))
        }
        return (pixel(x: 1, y: 1), pixel(x: width / 2, y: height / 2))
    }

    @Test("Settings clamp the type size into a legible range")
    func typeSizeClamped() {
        let settings = BeautifySettings(unifySizeAndSpacing: false)
        #expect(settings.typeSize(forInkHeight: 2) >= BeautifySettings.fontSizeRange.lowerBound)
        #expect(settings.typeSize(forInkHeight: 999) <= BeautifySettings.fontSizeRange.upperBound)

        let unified = BeautifySettings(unifySizeAndSpacing: true, fontSize: 31)
        #expect(unified.typeSize(forInkHeight: 8) == 31)
        #expect(unified.typeSize(forInkHeight: 80) == 31)
    }
}

/// The straight-edge does a real ruler's job: ink drawn down its side comes out
/// straight however much the hand wandered.
@Suite("Ruler guide")
struct RulerGuideTests {
    /// A ruler lying flat across the page, 44 points wide.
    private let guide = RulerGuide(
        start: CGPoint(x: 100, y: 400), end: CGPoint(x: 600, y: 400), halfWidth: 22
    )

    /// A wobbly hand running along the ruler's lower edge (y = 422).
    private func alongLowerEdge(wobble: CGFloat = 6) -> [CGPoint] {
        (0...40).map { index in
            let t = CGFloat(index) / 40
            return CGPoint(x: 120 + t * 400, y: 428 + sin(t * .pi * 3) * wobble)
        }
    }

    @Test("A wobbly line drawn down the edge comes out exactly straight")
    func straightensAlongTheEdge() throws {
        let ruled = try #require(guide.straightened(alongLowerEdge()))
        #expect(ruled.count == 2)
        // Both ends sit on the ruler's lower edge, and the wobble is gone.
        #expect(abs(ruled[0].y - 422) < 0.001)
        #expect(abs(ruled[1].y - 422) < 0.001)
        // It keeps the length it was drawn at, and the direction of the hand.
        #expect(ruled[0].x < ruled[1].x)
        #expect(abs(ruled[1].x - ruled[0].x - 400) < 1)
    }

    @Test("Drawn right to left, it stays right to left")
    func keepsTheDirection() throws {
        let backwards = Array(alongLowerEdge().reversed())
        let ruled = try #require(guide.straightened(backwards))
        #expect(ruled[0].x > ruled[1].x)
    }

    @Test("Each long edge guides, so it works on both sides")
    func bothEdgesGuide() throws {
        let above = (0...30).map { index -> CGPoint in
            let t = CGFloat(index) / 30
            return CGPoint(x: 150 + t * 300, y: 372 + sin(t * .pi * 2) * 5)
        }
        let ruled = try #require(guide.straightened(above))
        #expect(abs(ruled[0].y - 378) < 0.001, "the upper edge, not the lower one")
    }

    @Test("Writing elsewhere on the page is left completely alone")
    func ignoresInkAwayFromTheRuler() {
        let elsewhere = (0...30).map { index -> CGPoint in
            let t = CGFloat(index) / 30
            return CGPoint(x: 120 + t * 300, y: 700 + sin(t * .pi * 2) * 8)
        }
        #expect(guide.straightened(elsewhere) == nil)
    }

    @Test("A mark drawn ACROSS the ruler is not flattened into it")
    func ignoresStrokesAcrossTheEdge() {
        // Crossing a t against the ruler's edge must stay a crossed t, not become
        // another line down the edge.
        let tick = (0...10).map { index -> CGPoint in
            CGPoint(x: 300, y: 410 + CGFloat(index) * 3)
        }
        #expect(guide.straightened(tick) == nil)
    }

    @Test("A dot beside the ruler is not a ruled line")
    func ignoresTinyMarks() {
        let dot = [CGPoint(x: 300, y: 424), CGPoint(x: 302, y: 425)]
        #expect(guide.straightened(dot) == nil)
    }

    @Test("With no inset, nothing changes (regression guard)")
    func zeroInsetMatchesUninset() throws {
        let withDefault = try #require(guide.straightened(alongLowerEdge()))
        let withZero = try #require(guide.straightened(alongLowerEdge(), inset: 0))
        #expect(withDefault == withZero)
    }

    @Test("Inset nudges the ruled line AWAY from the ruler, by exactly the inset")
    func insetPushesOutwardOnTheLowerEdge() throws {
        // The lower edge sits at y = 422; its outward direction is further
        // DOWN the page (larger y), away from the ruler's body above it.
        let ruled = try #require(guide.straightened(alongLowerEdge(), inset: 5))
        #expect(abs(ruled[0].y - 427) < 0.001)
        #expect(abs(ruled[1].y - 427) < 0.001)
    }

    @Test("A single stray sample near touch-down/lift-off doesn't sink an otherwise-clean run")
    func toleratesOneStraySampleInTheAspectTest() throws {
        var points = (0...20).map { index -> CGPoint in
            let t = CGFloat(index) / 20
            return CGPoint(x: 150 + t * 400, y: 422 + sin(t * .pi * 2) * 2)
        }
        // A pencil that hasn't fully settled on touch-down can report one wild
        // sample far from the edge. The strict-MAX version of the aspect check
        // let that single point sink the whole stroke back to freehand even
        // though every other sample hugs the ruler; the 90th-percentile version
        // shouldn't.
        points.insert(CGPoint(x: 150, y: 622), at: 1)
        let ruled = try #require(guide.straightened(points))
        #expect(abs(ruled[0].y - 422) < 1)
        #expect(abs(ruled[1].y - 422) < 1)
    }

    @Test("A stroke genuinely drawn across the ruler still isn't flattened into it")
    func stillRejectsATrueCrossStrokeDespitePercentileTolerance() {
        // Unlike the single-outlier case above, HALF the samples run away from
        // the edge — a real crossed stroke, not a settling artifact — so this
        // must still fail the aspect test.
        let crossed = (0...20).map { index -> CGPoint in
            let t = CGFloat(index) / 20
            return CGPoint(x: 300 + t * 20, y: 422 + t * 200)
        }
        #expect(guide.straightened(crossed) == nil)
    }

    @Test("Inset pushes the OTHER way on the upper edge")
    func insetPushesOutwardOnTheUpperEdge() throws {
        let above = (0...30).map { index -> CGPoint in
            let t = CGFloat(index) / 30
            return CGPoint(x: 150 + t * 300, y: 372 + sin(t * .pi * 2) * 5)
        }
        // The upper edge sits at y = 378; outward is further UP the page
        // (smaller y).
        let ruled = try #require(guide.straightened(above, inset: 5))
        #expect(abs(ruled[0].y - 373) < 0.001)
    }
}
