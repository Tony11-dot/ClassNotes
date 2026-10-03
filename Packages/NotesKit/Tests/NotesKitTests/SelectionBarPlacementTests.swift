import CoreGraphics
import Foundation
import Testing
@testable import NotesEditor

/// Where the selection's Copy / Duplicate / Delete / Done bar actually lands.
///
/// This used to clamp to the top margin when there was no room above the
/// selection, which laid the bar straight over the top of whatever had just
/// been circled — the buttons covering the thing they were about to act on. It
/// was also clamped horizontally against a hardcoded number unrelated to its
/// real width, so adding a button would have pushed it off the right edge.
///
/// Tested as geometry rather than by rendering: the bar is drawn on `dsGlass`,
/// and `ImageRenderer` rasterizes a material as nothing at all, so reading
/// pixels back finds an empty page whether the bar is placed well, placed
/// off-screen, or placed on top of the selection.
@Suite("The selection's buttons stay reachable")
struct SelectionBarPlacementTests {
    private let display = CGSize(width: 768, height: 1024)
    private let bar = CGSize(width: 188, height: 40)

    private func origin(_ selection: CGRect) -> CGPoint {
        SelectionBarPlacement.origin(for: selection, barSize: bar, in: display)
    }

    @Test("With room above, the bar sits just above the selection")
    func sitsAboveWhenThereIsRoom() {
        let selection = CGRect(x: 200, y: 400, width: 300, height: 200)
        let point = origin(selection)
        #expect(point.y == selection.minY - bar.height - SelectionBarPlacement.gap)
        #expect(point.y + bar.height < selection.minY)
        #expect(point.x == selection.minX)
    }

    @Test("A selection at the very top pushes the bar BELOW it, never over it")
    func flipsBelowAtTheTopOfThePage() {
        for top in [CGFloat(0), 4, 20, 55] {
            let selection = CGRect(x: 200, y: top, width: 300, height: 180)
            let point = origin(selection)
            // Clear of the selection entirely — this is the whole point.
            let overlaps = point.y < selection.maxY && point.y + bar.height > selection.minY
            #expect(!overlaps, "bar overlapped a selection at y=\(top)")
            #expect(point.y >= selection.maxY)
        }
    }

    @Test("A selection against the right edge keeps the whole bar on screen")
    func staysOnScreenAtTheRightEdge() {
        let selection = CGRect(x: display.width - 120, y: 500, width: 110, height: 150)
        let point = origin(selection)
        #expect(point.x + bar.width <= display.width - SelectionBarPlacement.margin)
        #expect(point.x >= SelectionBarPlacement.margin)
    }

    @Test("A selection off the left edge still leaves the bar on screen")
    func staysOnScreenAtTheLeftEdge() {
        let point = origin(CGRect(x: -80, y: 500, width: 200, height: 100))
        #expect(point.x == SelectionBarPlacement.margin)
    }

    @Test("A selection filling the whole page still gets its bar somewhere visible")
    func alwaysLandsOnScreen() {
        let selection = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let point = origin(selection)
        #expect(point.y >= SelectionBarPlacement.margin)
        #expect(point.y + bar.height <= display.height)
        #expect(point.x >= SelectionBarPlacement.margin)
        #expect(point.x + bar.width <= display.width)
    }

    /// The bar's width is derived from its buttons, so a fifth action cannot
    /// quietly start hanging off the right edge the way a hardcoded clamp would
    /// have let it.
    @Test("A wider bar is clamped by its own width, not a remembered constant")
    func clampFollowsTheBarsOwnWidth() {
        let selection = CGRect(x: display.width - 60, y: 400, width: 50, height: 50)
        let wide = CGSize(width: 320, height: 40)
        let point = SelectionBarPlacement.origin(for: selection, barSize: wide, in: display)
        #expect(point.x + wide.width <= display.width - SelectionBarPlacement.margin)
    }
}

/// Where a pasted copy lands.
///
/// Paste used to land at EXACTLY the frame it was copied from, which — when the
/// source is still sitting there — puts a pixel-identical picture directly over
/// the original and reads as "paste did nothing". It is nudged now, the same
/// way Duplicate is; this pins the part that nudging on its own gets wrong,
/// which is a copy taken from the edge of the page being pushed off it.
@Suite("A pasted copy lands where it can be seen")
struct PasteLandingTests {
    private let page = CGSize(width: 768, height: 1024)

    private func landing(_ source: CGRect) -> CGRect {
        EditorScreen.landingFrame(for: source, offsetBy: 24, onPageOfSize: page)
    }

    @Test("In open space it simply lands offset, so it reads as a second thing")
    func nudgedInOpenSpace() {
        let source = CGRect(x: 100, y: 200, width: 150, height: 120)
        #expect(landing(source) == CGRect(x: 124, y: 224, width: 150, height: 120))
    }

    @Test("A copy from the bottom-right corner is kept on the page")
    func clampedAtTheFarCorner() {
        let source = CGRect(x: page.width - 160, y: page.height - 130, width: 150, height: 120)
        let landed = landing(source)
        #expect(landed.maxX <= page.width)
        #expect(landed.maxY <= page.height)
        #expect(landed.width == source.width)
        #expect(landed.height == source.height)
    }

    @Test("Nothing is dragged to negative coordinates")
    func neverLandsAboveOrLeftOfThePage() {
        let landed = landing(CGRect(x: -40, y: -60, width: 100, height: 100))
        #expect(landed.minX >= 0)
        #expect(landed.minY >= 0)
    }

    @Test("A region bigger than the page is left alone rather than shoved about")
    func oversizedIsLeftWhereItIs() {
        let source = CGRect(x: 0, y: 0, width: page.width + 200, height: page.height + 200)
        let landed = landing(source)
        #expect(landed.width == source.width)
        #expect(landed.height == source.height)
    }

    @Test("With no page size known, the nudge still applies")
    func unknownPageStillNudges() {
        let landed = EditorScreen.landingFrame(
            for: CGRect(x: 10, y: 10, width: 50, height: 50), offsetBy: 24, onPageOfSize: .zero
        )
        #expect(landed == CGRect(x: 34, y: 34, width: 50, height: 50))
    }
}
