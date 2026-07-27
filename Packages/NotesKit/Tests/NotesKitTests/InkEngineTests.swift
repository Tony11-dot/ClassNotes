import CoreGraphics
import Foundation
import NotesModels
import PencilKit
import Testing
@testable import NotesEditor

@Suite("Stroke smoothing (pen stability)")
struct StrokeSmoothingTests {
    @Test("Stability 1 is the identity — the pencil's own path is untouched")
    func identityAtLowestStability() {
        let points = (0..<20).map { CGPoint(x: Double($0), y: Double($0 % 3)) }
        #expect(StrokeSmoothing.window(forStability: 1) == 1)
        #expect(StrokeSmoothing.smooth(points, stability: 1) == points)
    }

    @Test("Higher stability shrinks tremor but keeps the endpoints pinned")
    func smoothingReducesJitter() {
        // A straight line with alternating ±4 pt jitter on top of it.
        let points = (0..<40).map { index in
            CGPoint(x: Double(index) * 5, y: index % 2 == 0 ? 4 : -4)
        }
        let smoothed = StrokeSmoothing.smooth(points, stability: 6)

        #expect(smoothed.first == points.first, "the stroke still starts where the pencil landed")
        #expect(smoothed.last == points.last, "and ends where it lifted")
        #expect(smoothed.count == points.count)

        let before = deviation(points)
        let after = deviation(smoothed)
        #expect(after < before / 2, "expected the jitter to more than halve, got \(after) from \(before)")
    }

    @Test("Windows grow monotonically with stability")
    func windowGrows() {
        let windows = PenSettings.stabilityRange.map(StrokeSmoothing.window(forStability:))
        #expect(windows == windows.sorted())
        #expect(Set(windows).count == windows.count)
    }

    @Test("Paths too short to average are returned unchanged")
    func shortPaths() {
        let two = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        #expect(StrokeSmoothing.smooth(two, stability: 7) == two)
        #expect(StrokeSmoothing.smooth([], stability: 7).isEmpty)
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

@Suite("Pen shaping")
struct PenShaperTests {
    private func stroke(points: Int = 24, size: CGFloat = 3) -> PKStroke {
        let controlPoints = (0..<points).map { index in
            PKStrokePoint(
                location: CGPoint(x: Double(index) * 4, y: index % 2 == 0 ? 3 : -3),
                timeOffset: Double(index) * 0.01,
                // Alternating point sizes stand in for varying pressure.
                size: CGSize(width: index % 2 == 0 ? size * 2 : size, height: size),
                opacity: 1, force: index % 2 == 0 ? 2 : 0.5,
                azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSince1970: 0))
        )
    }

    @Test("Neutral settings are a no-op, so an untouched pen costs nothing")
    func neutralIsNoOp() {
        let settings = PenSettings(stability: 1, sensitivity: 0.5)
        #expect(PenShaper.shaped(stroke(), settings: settings) == nil)
    }

    @Test("Every shipped pen preset that reads as neutral rebuilds nothing")
    func shippedDefaultsAvoidPointlessRebuilds() {
        // Shaping a stroke means reassigning the canvas's whole drawing, which is
        // what made writing feel laggier the fuller the page got. The DEFAULT pen
        // must not pay that for a difference nobody can see.
        let flow = PenLibrary.default
        #expect(
            PenShaper.shaped(stroke(), settings: flow.defaults) == nil,
            "the default Flow Pen must not rebuild strokes"
        )
        // …while a pen whose character really is "even line" or "wet nib" still does.
        for id in ["fineliner", "fountain", "highlighter"] {
            let preset = PenLibrary.preset(id: id)
            #expect(
                PenShaper.shaped(stroke(), settings: preset.defaults) != nil,
                "\(id) is tuned away from neutral and should still be shaped"
            )
        }
    }

    @Test("Stability smooths the path and keeps the ink and point count")
    func stabilityReshapes() throws {
        let original = stroke()
        let shaped = try #require(
            PenShaper.shaped(original, settings: PenSettings(stability: 5, sensitivity: 0.5))
        )
        #expect(shaped.path.count == original.path.count)
        #expect(shaped.ink.inkType == original.ink.inkType)

        let interior = Array(shaped.path).dropFirst().dropLast()
        let jitter = interior.reduce(0.0) { $0 + abs(Double($1.location.y)) } / Double(interior.count)
        #expect(jitter < 3, "expected the ±3 pt tremor to settle, got \(jitter)")
    }

    @Test("Zero sensitivity flattens pressure into an even line")
    func sensitivityFlattens() throws {
        let shaped = try #require(
            PenShaper.shaped(stroke(), settings: PenSettings(stability: 1, sensitivity: 0))
        )
        let widths = Set(Array(shaped.path).map { ($0.size.width * 100).rounded() })
        #expect(widths.count == 1, "every point should be the same width, got \(widths)")
    }

    @Test("Full sensitivity widens the gap between light and heavy points")
    func sensitivityExaggerates() throws {
        let original = stroke()
        let shaped = try #require(
            PenShaper.shaped(original, settings: PenSettings(stability: 1, sensitivity: 1))
        )
        #expect(spread(of: shaped) > spread(of: original))
    }

    @Test("Tip folds into the width handed to PencilKit")
    func tipDrivesWidth() {
        let thin = PenSettings(tip: 0.1, thickness: 4)
        let fat = PenSettings(tip: 1, thickness: 4)
        #expect(thin.effectiveWidth < fat.effectiveWidth)
        #expect(PenSettings(tip: 0.05, thickness: 0.4).effectiveWidth > 0)
    }

    private func spread(of stroke: PKStroke) -> CGFloat {
        let widths = Array(stroke.path).map(\.size.width)
        return (widths.max() ?? 0) - (widths.min() ?? 0)
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

    @Test("Typeset text lands on the handwriting's own line")
    func framesOnBaseline() {
        let ink = CGRect(x: 90, y: 200, width: 300, height: 34)
        let frame = BeautifyLayout.frame(
            inkBounds: ink, typeSize: 24, lineSpacing: 1.2,
            characterCount: 22, in: pageSize
        )
        #expect(abs(frame.minX - ink.minX) < 1, "it starts where the writing started")
        #expect(abs(frame.midY - ink.midY) < 2, "and sits on the same line")
        #expect(frame.height >= 24)
    }

    @Test("Frames stay on the page, however near the edge the writing was")
    func clampsToPage() {
        let edge = CGRect(x: pageSize.width - 20, y: pageSize.height - 10, width: 300, height: 30)
        let frame = BeautifyLayout.frame(
            inkBounds: edge, typeSize: 22, lineSpacing: 1.2, characterCount: 40, in: pageSize
        )
        #expect(frame.minX >= 0)
        #expect(frame.maxX <= pageSize.width + 0.01)
        #expect(frame.maxY <= pageSize.height + 0.01)
    }

    @Test("Longer text gets a wider box")
    func widthTracksLength() {
        let ink = CGRect(x: 40, y: 100, width: 60, height: 24)
        let short = BeautifyLayout.frame(
            inkBounds: ink, typeSize: 20, lineSpacing: 1.2, characterCount: 4, in: pageSize
        )
        let long = BeautifyLayout.frame(
            inkBounds: ink, typeSize: 20, lineSpacing: 1.2, characterCount: 30, in: pageSize
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

    @Test("Merging widens the run without moving or growing its line")
    func mergeKeepsBaseline() {
        let run = CGRect(x: 60, y: 200, width: 180, height: 30)
        let more = CGRect(x: 250, y: 202, width: 90, height: 28)
        let merged = BeautifyLayout.merged(existing: run, incoming: more, in: pageSize)
        #expect(merged.minX == run.minX)
        #expect(merged.minY == run.minY)
        #expect(merged.height == run.height)
        #expect(merged.width > run.width)
    }
}

@MainActor
@Suite("Real-time beautification planning")
struct LiveBeautifierPlanTests {
    private let pageSize = PageSize.a4.portraitSize

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
            pageSize: pageSize
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
            colorHex: nil, pageSize: pageSize
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
            fontName: "Georgia", colorHex: nil, pageSize: pageSize
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
            fontName: "Georgia", colorHex: nil, pageSize: pageSize
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
                fontName: "Georgia", colorHex: nil, pageSize: pageSize
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
            fontName: "Georgia", colorHex: nil, pageSize: pageSize
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
        let small = LiveBeautifier.renderScale(for: CGRect(x: 0, y: 0, width: 100, height: 14))
        let large = LiveBeautifier.renderScale(for: CGRect(x: 0, y: 0, width: 400, height: 110))
        #expect(small > large)
        #expect(small <= 8)
        #expect(large >= 2)
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
