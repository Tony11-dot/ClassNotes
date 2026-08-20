import CoreGraphics
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
