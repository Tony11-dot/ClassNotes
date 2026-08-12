import CoreGraphics
import Testing
@testable import NotesEditor

@MainActor
@Suite("How wide a page is drawn")
struct PageLayoutTests {
    @Test("A page fills the window, less its gutters, up to the maximum")
    func fitsTheWindow() {
        // A narrow window: the page takes what's there minus the gutters.
        let narrow = EditorScreen.pageWidth(in: 600, zoom: 1)
        #expect(narrow == 600 - EditorScreen.pageGutter * 2)

        // A wide one: the page stops growing at its own maximum rather than
        // stretching across a 13-inch iPad.
        let wide = EditorScreen.pageWidth(in: 1_600, zoom: 1)
        #expect(wide == EditorScreen.maximumPageWidth)
    }

    @Test("A page is never smaller than it is usable at")
    func neverCollapses() {
        // This is the bug that made the editor untestable: pages laid out inside
        // an unbounded scroll view resolved to nothing and drew as dots. Whatever
        // the container claims, the page has a real size.
        for container in [CGFloat(0), 1, 40, 80, 120] {
            let width = EditorScreen.pageWidth(in: container, zoom: 1)
            #expect(width >= EditorScreen.minimumPageWidth)
        }
    }

    @Test("Zoom scales the width and stays inside its own bounds")
    func zoomScales() {
        let base = EditorScreen.pageWidth(in: 1_600, zoom: 1)
        #expect(EditorScreen.pageWidth(in: 1_600, zoom: 2) == base * 2)

        // Past the ends of the range, the clamp holds.
        let tiny = EditorScreen.pageWidth(in: 1_600, zoom: 0.01)
        #expect(tiny == base * EditorScreen.zoomRange.lowerBound)
        let huge = EditorScreen.pageWidth(in: 1_600, zoom: 99)
        #expect(huge == base * EditorScreen.zoomRange.upperBound)
    }

    @Test("Height comes from the page's own proportions")
    func heightFollowsAspectRatio() {
        // 3:4 portrait paper, 600 points wide, is 800 tall.
        let size = EditorScreen.pageSize(aspectRatio: 0.75, width: 600)
        #expect(size.width == 600)
        #expect(abs(size.height - 800) < 0.001)
    }

    @Test("A nonsense aspect ratio still produces a usable page")
    func survivesABadRatio() {
        for ratio in [CGFloat(0), -1] {
            let size = EditorScreen.pageSize(aspectRatio: ratio, width: 600)
            #expect(size.height > 0)
            #expect(size.height.isFinite)
        }
    }

    @Test("A snapshot is crisp when small and capped when large")
    func snapshotScaleIsBounded() {
        #expect(EditorScreen.snapshotScale(for: CGSize(width: 100, height: 80)) == 3)
        let big = EditorScreen.snapshotScale(for: CGSize(width: 4_000, height: 3_000))
        #expect(big == 1)
        // Whatever the region, the render is never blurred (scale below 1) and a
        // small selection is never blown up past the pixel budget. A region
        // already larger than the budget is drawn 1:1 rather than shrunk — a
        // snapshot that loses detail is worse than a large one.
        for side in [CGFloat(50), 400, 1_200, 2_400, 6_000] {
            let scale = EditorScreen.snapshotScale(for: CGSize(width: side, height: side))
            #expect(scale >= 1)
            #expect(scale <= 3)
            #expect(side * scale <= max(side, 2_400))
        }
    }
}
