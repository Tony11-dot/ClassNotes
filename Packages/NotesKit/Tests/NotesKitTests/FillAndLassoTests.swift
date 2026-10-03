import CoreGraphics
import Foundation
import Testing
@testable import NotesModels

/// A mask with a hollow rectangle of "ink" drawn on it, so a fill has somewhere
/// to be contained and somewhere to escape from.
private func boxMask(
    width: Int = 40, height: Int = 40,
    box: (x: Int, y: Int, w: Int, h: Int) = (8, 8, 24, 24),
    gapAtTop: Bool = false
) -> FillGeometry.Mask {
    var mask = FillGeometry.Mask(width: width, height: height)
    for x in box.x...(box.x + box.w) {
        // A gap in the top edge is a shape somebody didn't quite close.
        if !(gapAtTop && x > box.x + 10 && x < box.x + 14) {
            mask[x, box.y] = true
        }
        mask[x, box.y + box.h] = true
    }
    for y in box.y...(box.y + box.h) {
        mask[box.x, y] = true
        mask[box.x + box.w, y] = true
    }
    return mask
}

@Suite("Flood fill")
struct FillGeometryTests {
    @Test("A tap inside a closed shape fills that shape and nothing else")
    func fillsTheInterior() throws {
        let mask = boxMask()
        let region = try #require(FillGeometry.region(in: mask, from: (20, 20)))
        #expect(region[20, 20])
        #expect(region[10, 10], "the whole interior is reached")
        // Outside the box, and the ink itself, are untouched.
        #expect(!region[2, 2])
        #expect(!region[8, 8], "the outline is a wall, not part of the fill")
        #expect(!region[35, 35])
    }

    @Test("A shape with a gap in it fills everything the colour can reach")
    func openShapeFillsWhatItReaches() throws {
        // The paint escapes through the gap and washes the page. That is what the
        // user asked for by tapping there — the fill draws UNDER the ink, so a
        // page-wide wash costs them nothing, whereas refusing meant the bucket did
        // nothing at all on any shape drawn slightly open.
        let leaky = boxMask(gapAtTop: true)
        let region = try #require(FillGeometry.region(in: leaky, from: (20, 20)))
        #expect(region[20, 20], "the inside is filled")
        #expect(region[2, 2], "and so is the page outside it, through the gap")
        #expect(!region[8, 8], "the ink is still a wall")
    }

    @Test("A caller that wants to refuse a runaway fill still can")
    func coverageLimitIsHonoured() {
        let leaky = boxMask(gapAtTop: true)
        #expect(FillGeometry.region(in: leaky, from: (20, 20), coverageLimit: 0.5) == nil)
    }

    @Test("A tap on the ink is nudged to the space beside it")
    func tapOnInkFindsTheSpace() throws {
        // Aiming the bucket at a line is a miss by a pixel or two, not a change of
        // mind: the region the tap was aimed at is the one right beside it.
        let mask = boxMask()
        #expect(FillGeometry.region(in: mask, from: (8, 8)) == nil, "the seed itself is ink")
        let nudged = try #require(FillGeometry.freePixel(near: (8, 8), in: mask))
        #expect(!mask[nudged.x, nudged.y])
        #expect(FillGeometry.region(in: mask, from: (-1, 5)) == nil, "and off the page")
        // Buried in ink with nothing near it, there is genuinely nothing to fill.
        let solid = FillGeometry.Mask(width: 8, height: 8, repeating: true)
        #expect(FillGeometry.freePixel(near: (4, 4), in: solid) == nil)
    }

    @Test("The traced outline wraps the region it came from")
    func outlineWrapsTheRegion() throws {
        let mask = boxMask()
        let region = try #require(FillGeometry.region(in: mask, from: (20, 20)))
        let outline = FillGeometry.outline(of: region)
        #expect(outline.count > 8)
        let xs = outline.map(\.x), ys = outline.map(\.y)
        // Inside the ink walls (9…31), never outside them.
        #expect((xs.min() ?? 0) >= 9)
        #expect((xs.max() ?? 0) <= 31)
        #expect((ys.min() ?? 0) >= 9)
        #expect((ys.max() ?? 0) <= 31)
    }

    @Test("Simplifying keeps the shape and drops the pixel-by-pixel padding")
    func simplifyKeepsTheShape() {
        // A straight run of 100 points is two points' worth of information.
        let line = (0...100).map { CGPoint(x: CGFloat($0), y: 10) }
        #expect(FillGeometry.simplified(line, tolerance: 0.5).count == 2)

        // A corner survives.
        let corner = (0...50).map { CGPoint(x: CGFloat($0), y: 10) }
            + (11...50).map { CGPoint(x: 50, y: CGFloat($0)) }
        #expect(FillGeometry.simplified(corner, tolerance: 0.5).count == 3)
    }

    @Test("A traced outline becomes a page-space path that tucks under the ink")
    func pathScalesBackToThePage() {
        let square = [
            CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 20),
            CGPoint(x: 60, y: 60), CGPoint(x: 20, y: 60), CGPoint(x: 20, y: 20)
        ]
        let path = FillGeometry.path(forOutline: square, maskOrigin: .zero, scale: 2)
        #expect(path.count >= 4)
        // Scaled back to page points (÷2) and grown outward, so the colour runs
        // under the stroke instead of leaving a pale halo beside it.
        let xs = path.map(\.x)
        #expect((xs.min() ?? 0) < 10)
        #expect((xs.max() ?? 0) > 30)
    }

    @Test("An empty or degenerate outline produces no path at all")
    func degenerateOutlinesAreDropped() {
        #expect(FillGeometry.path(forOutline: [], maskOrigin: .zero, scale: 2).isEmpty)
        #expect(FillGeometry.path(
            forOutline: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)],
            maskOrigin: .zero, scale: 2
        ).isEmpty)
        #expect(FillGeometry.path(
            forOutline: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 1)],
            maskOrigin: .zero, scale: 0
        ).isEmpty, "a zero scale would divide by nothing")
    }

    @Test("No erased points leaves the outline exactly as it was")
    func noErasedPointsIsANoOp() {
        let square = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)
        ]
        #expect(FillGeometry.erased(outline: square, erasedPoints: [], radius: 5, scale: 1) == square)
    }

    @Test("Erasing a corner takes only a bite, not the whole fill")
    func erasingTakesOnlyABite() throws {
        let square = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0)
        ]
        let bitten = try #require(FillGeometry.erased(
            outline: square, erasedPoints: [CGPoint(x: 0, y: 0)], radius: 20, scale: 1
        ))
        let xs = bitten.map(\.x), ys = bitten.map(\.y)
        // The far corner never had the eraser near it, so it's still there.
        #expect((xs.max() ?? 0) > 90)
        #expect((ys.max() ?? 0) > 90)
        // The near corner is gone: nothing in the surviving outline sits
        // inside the bitten radius any more.
        #expect(!bitten.contains { hypot($0.x, $0.y) < 15 })
    }

    @Test("Erasing the whole area leaves nothing to fall back on")
    func erasingEverythingDeletesTheFill() {
        let square = [
            CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0),
            CGPoint(x: 40, y: 40), CGPoint(x: 0, y: 40), CGPoint(x: 0, y: 0)
        ]
        let survivors = FillGeometry.erased(
            outline: square, erasedPoints: [CGPoint(x: 20, y: 20)], radius: 60, scale: 1
        )
        #expect(survivors == nil, "nothing survived, so the caller should delete the element")
    }

    @Test("A cut near one edge keeps the larger remaining piece, not the sliver")
    func erasingThroughTheMiddleKeepsTheBiggerHalf() throws {
        let rect = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 40), CGPoint(x: 0, y: 40), CGPoint(x: 0, y: 0)
        ]
        // A vertical stripe of eraser contact ten points in from the left
        // edge — carving the rectangle into a thin sliver (x < 4ish) and a
        // much bigger slab (x > 16ish).
        let stripe = stride(from: 0, through: 40, by: 2).map { CGPoint(x: 10, y: CGFloat($0)) }
        let survivor = try #require(FillGeometry.erased(
            outline: rect, erasedPoints: stripe, radius: 6, scale: 1
        ))
        let xs = survivor.map(\.x)
        #expect((xs.max() ?? 0) > 90, "the big slab past the cut survives")
        #expect((xs.min() ?? 0) > 4, "the thin sliver on the near side of the cut is the smaller piece, discarded")
    }
}

@Suite("Lasso selection")
struct LassoSelectionTests {
    /// A square loop from (100,100) to (300,300).
    private let loop = [
        CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100),
        CGPoint(x: 300, y: 300), CGPoint(x: 100, y: 300), CGPoint(x: 100, y: 100)
    ]

    @Test("Inside is inside, outside is outside")
    func pointContainment() {
        #expect(LassoSelection.contains(loop, CGPoint(x: 200, y: 200)))
        #expect(!LassoSelection.contains(loop, CGPoint(x: 50, y: 200)))
        #expect(!LassoSelection.contains(loop, CGPoint(x: 200, y: 400)))
        #expect(!LassoSelection.contains([], CGPoint(x: 200, y: 200)))
    }

    @Test("A stroke mostly inside the loop is caught; one that only grazes it is not")
    func strokeCoverage() {
        let inside = (0...10).map { CGPoint(x: 150 + CGFloat($0) * 10, y: 200) }
        #expect(LassoSelection.catches(loop, inside))

        // A word beside the loop, clipped by one letter — circling generously
        // must not drag in the neighbour you were careful to avoid.
        let grazing = (0...10).map { CGPoint(x: 290 + CGFloat($0) * 20, y: 200) }
        #expect(!LassoSelection.catches(loop, grazing))
        #expect(!LassoSelection.catches(loop, []))
    }

    @Test("An element is caught by its centre, or by most of its corners")
    func elementCoverage() {
        #expect(LassoSelection.catches(loop, frame: CGRect(x: 150, y: 150, width: 60, height: 40)))
        // A big image whose centre is in but whose corners spill out.
        #expect(LassoSelection.catches(loop, frame: CGRect(x: 120, y: 120, width: 250, height: 250)))
        #expect(!LassoSelection.catches(loop, frame: CGRect(x: 400, y: 400, width: 40, height: 40)))
        #expect(!LassoSelection.catches(loop, frame: .null))
    }

    @Test("A loop that wasn't quite finished is closed for you")
    func closesAnOpenLoop() throws {
        let open = [
            CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 200)
        ]
        let closed = try #require(LassoSelection.closed(open))
        #expect(closed.first == closed.last)
        #expect(closed.count == open.count + 1)
    }

    @Test("A flick too small to be a deliberate circle selects nothing")
    func rejectsATinyScribble() {
        let flick = [
            CGPoint(x: 10, y: 10), CGPoint(x: 14, y: 12), CGPoint(x: 12, y: 15)
        ]
        #expect(LassoSelection.closed(flick) == nil)
        #expect(LassoSelection.closed([CGPoint(x: 1, y: 1)]) == nil)
    }

    @Test("The selection box wraps everything caught, with room for the outline")
    func boundsWrapTheCatch() throws {
        let box = try #require(LassoSelection.bounds(of: [
            CGRect(x: 100, y: 100, width: 50, height: 20),
            CGRect(x: 200, y: 140, width: 30, height: 30)
        ], padding: 8))
        #expect(box.minX == 92)
        #expect(box.minY == 92)
        #expect(box.maxX == 238)
        #expect(box.maxY == 178)
        #expect(LassoSelection.bounds(of: []) == nil)
    }
}

// MARK: - Holes

/// Draws a ring of ink of the given radius and thickness.
private func ring(_ mask: inout FillGeometry.Mask, centre: CGPoint, radius: CGFloat, width: CGFloat = 2) {
    for y in 0..<mask.height {
        for x in 0..<mask.width
        where abs(hypot(CGFloat(x) - centre.x, CGFloat(y) - centre.y) - radius) <= width {
            mask[x, y] = true
        }
    }
}

/// Draws the outline of a box of ink.
private func frame(_ mask: inout FillGeometry.Mask, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
    for x in x0...x1 { mask[x, y0] = true; mask[x, y1] = true }
    for y in y0...y1 { mask[x0, y] = true; mask[x1, y] = true }
}

/// Even-odd point-in-polygon over several rings — how the fill is drawn.
private func painted(_ point: CGPoint, outline: [CGPoint], holes: [[CGPoint]]) -> Bool {
    var inside = false
    for ring in [outline] + holes {
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
    }
    return inside
}

@Suite("A fill goes round what it encloses")
struct FillHoleTests {
    @Test("Between two circles, the inner disc is a hole — not painted")
    func concentricCirclesLeaveTheMiddle() throws {
        var mask = FillGeometry.Mask(width: 200, height: 200)
        ring(&mask, centre: CGPoint(x: 100, y: 100), radius: 80)
        ring(&mask, centre: CGPoint(x: 100, y: 100), radius: 30)
        let region = try #require(FillGeometry.region(in: mask, from: (100, 40)))
        let outline = FillGeometry.path(
            forOutline: FillGeometry.outline(of: region), maskOrigin: .zero, scale: 1
        )
        let holes = FillGeometry.holes(in: region, ink: mask, minimumEnclosedPixels: 100)
            .map { FillGeometry.path(forOutline: $0, maskOrigin: .zero, scale: 1, growth: -1.2) }

        #expect(holes.count == 1)
        // The bug: one ring traced, so the centre was painted with the band.
        #expect(!painted(CGPoint(x: 100, y: 100), outline: outline, holes: holes))
        #expect(painted(CGPoint(x: 100, y: 45), outline: outline, holes: holes), "the band itself is")
        #expect(!painted(CGPoint(x: 5, y: 5), outline: outline, holes: holes), "outside is not")
    }

    @Test("A box drawn inside a box stays unpainted, every one of them")
    func boxesInsideABox() throws {
        var mask = FillGeometry.Mask(width: 200, height: 200)
        frame(&mask, 10, 10, 190, 190)
        frame(&mask, 30, 30, 80, 80)
        frame(&mask, 110, 110, 170, 170)
        let region = try #require(FillGeometry.region(in: mask, from: (150, 40)))
        let outline = FillGeometry.path(
            forOutline: FillGeometry.outline(of: region), maskOrigin: .zero, scale: 1
        )
        let holes = FillGeometry.holes(in: region, ink: mask, minimumEnclosedPixels: 100)
            .map { FillGeometry.path(forOutline: $0, maskOrigin: .zero, scale: 1, growth: -1.2) }

        #expect(holes.count == 2)
        #expect(!painted(CGPoint(x: 55, y: 55), outline: outline, holes: holes))
        #expect(!painted(CGPoint(x: 140, y: 140), outline: outline, holes: holes))
        #expect(painted(CGPoint(x: 100, y: 50), outline: outline, holes: holes))
    }

    @Test("Writing inside a shape is not a hole — the paint stays behind the words")
    func smallEnclosuresStayPainted() throws {
        var mask = FillGeometry.Mask(width: 200, height: 200)
        frame(&mask, 10, 10, 190, 190)
        // A written "o": a little loop, far below the hole threshold.
        ring(&mask, centre: CGPoint(x: 100, y: 100), radius: 5, width: 1)
        let region = try #require(FillGeometry.region(in: mask, from: (40, 40)))
        #expect(FillGeometry.holes(in: region, ink: mask, minimumEnclosedPixels: 400).isEmpty)
    }

    @Test("A region with nothing inside it has no holes")
    func noHoles() throws {
        var mask = FillGeometry.Mask(width: 60, height: 60)
        frame(&mask, 5, 5, 55, 55)
        let region = try #require(FillGeometry.region(in: mask, from: (30, 30)))
        #expect(FillGeometry.holes(in: region, minimumEnclosedPixels: 1).isEmpty)
    }

    @Test("A fill that reaches the page edge has no phantom hole along it")
    func pageEdgeIsNotAHole() throws {
        var mask = FillGeometry.Mask(width: 100, height: 100)
        // A shape open to the page edge, and a closed shape in the open.
        frame(&mask, 40, 40, 60, 60)
        let region = try #require(FillGeometry.region(in: mask, from: (5, 5)))
        let holes = FillGeometry.holes(in: region, ink: mask, minimumEnclosedPixels: 50)
        #expect(holes.count == 1, "only the closed box is enclosed")
    }

    @Test("Erasing in the middle of a fill cuts a hole, and the holes it had stay cut")
    func erasingInTheMiddleCutsAHole() throws {
        let square = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0)
        ]
        // A dab in the middle touches no edge. Tracing only the outer ring used
        // to throw it away, so erasing there did nothing at all.
        let bitten = try #require(FillGeometry.erasedRegion(
            outline: square, holes: [], erasedPoints: [CGPoint(x: 50, y: 50)], radius: 10, scale: 1
        ))
        #expect(bitten.holes.count == 1)
        #expect(!painted(CGPoint(x: 50, y: 50), outline: bitten.outline, holes: bitten.holes))
        #expect(painted(CGPoint(x: 20, y: 20), outline: bitten.outline, holes: bitten.holes))

        // A hole the fill already had survives an erase somewhere else.
        let hole = [CGPoint(x: 60, y: 60), CGPoint(x: 85, y: 60), CGPoint(x: 85, y: 85), CGPoint(x: 60, y: 85)]
        let again = try #require(FillGeometry.erasedRegion(
            outline: square, holes: [hole], erasedPoints: [CGPoint(x: 0, y: 0)], radius: 10, scale: 1
        ))
        #expect(!painted(CGPoint(x: 72, y: 72), outline: again.outline, holes: again.holes))
        #expect(painted(CGPoint(x: 30, y: 70), outline: again.outline, holes: again.holes))
    }

    @Test("An erase lands where the eraser was, not mirrored to the other end")
    func eraseIsNotVerticallyMirrored() throws {
        // Every other fixture in this suite is symmetric about the horizontal
        // axis — a square, a dab in the dead centre — which is exactly the axis
        // that was being mirrored, so none of them could see it. A TALL region
        // erased near its TOP can.
        let tall = [
            CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0),
            CGPoint(x: 60, y: 300), CGPoint(x: 0, y: 300), CGPoint(x: 0, y: 0)
        ]
        let bitten = try #require(FillGeometry.erasedRegion(
            outline: tall, holes: [], erasedPoints: [CGPoint(x: 30, y: 30)], radius: 14, scale: 1
        ))
        // The bite is where the eraser went…
        #expect(!painted(CGPoint(x: 30, y: 30), outline: bitten.outline, holes: bitten.holes))
        // …and NOT at the mirror of it, 30 points up from the bottom.
        #expect(painted(CGPoint(x: 30, y: 270), outline: bitten.outline, holes: bitten.holes))
    }

    @Test("A hole keeps its own position through an erase elsewhere")
    func holeKeepsItsPlace() throws {
        let tall = [
            CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 0),
            CGPoint(x: 120, y: 300), CGPoint(x: 0, y: 300), CGPoint(x: 0, y: 0)
        ]
        // A hole well off centre, so a flip would move it somewhere obvious.
        let hole = [
            CGPoint(x: 40, y: 40), CGPoint(x: 80, y: 40),
            CGPoint(x: 80, y: 80), CGPoint(x: 40, y: 80)
        ]
        let after = try #require(FillGeometry.erasedRegion(
            outline: tall, holes: [hole], erasedPoints: [CGPoint(x: 5, y: 295)], radius: 8, scale: 1
        ))
        #expect(!painted(CGPoint(x: 60, y: 60), outline: after.outline, holes: after.holes))
        #expect(painted(CGPoint(x: 60, y: 240), outline: after.outline, holes: after.holes))
    }

    @Test("Holes survive a round trip through the manifest, and old fills decode without any")
    func holesRoundTrip() throws {
        let element = PageElement(
            kind: .fill, x: 0, y: 0, width: 10, height: 10,
            points: [PagePoint(x: 0, y: 0), PagePoint(x: 10, y: 0), PagePoint(x: 10, y: 10)],
            holes: [[PagePoint(x: 2, y: 2), PagePoint(x: 4, y: 2), PagePoint(x: 4, y: 4)]]
        )
        let decoded = try JSONDecoder().decode(PageElement.self, from: JSONEncoder().encode(element))
        #expect(decoded.holes == element.holes)

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(element)) as? [String: Any]
        legacy?["holes"] = nil
        let old = try JSONDecoder().decode(
            PageElement.self, from: JSONSerialization.data(withJSONObject: legacy ?? [:])
        )
        #expect(old.holes.isEmpty)
        #expect(old.points == element.points)
    }
}
