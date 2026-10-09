import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import NotesEditor
@testable import NotesModels
import NotesServices

private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool {
    abs(a - b) <= tolerance
}

private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.001) -> Bool {
    near(a.x, b.x, tolerance) && near(a.y, b.y, tolerance)
}

/// A strip of freeform tape as `insertTape` stores it: the path RELATIVE to the
/// strip's own frame.
private func tape(at origin: CGPoint) -> PageElement {
    PageElement(
        kind: .tape, x: origin.x, y: origin.y, width: 120, height: 40,
        tapeShape: .draw, tapePattern: .solid, colorHex: "#FFCC00",
        points: [PagePoint(x: 17, y: 20), PagePoint(x: 103, y: 20)], strokeWidth: 30
    )
}

private func fill() -> PageElement {
    PageElement(
        kind: .fill, x: 100, y: 100, width: 100, height: 50, colorHex: "#00AAFF",
        points: [
            PagePoint(x: 100, y: 100), PagePoint(x: 200, y: 100),
            PagePoint(x: 200, y: 150), PagePoint(x: 100, y: 150)
        ]
    )
}

private func textBox() -> PageElement {
    PageElement(kind: .text, x: 100, y: 100, width: 100, height: 20, text: "osmosis", colorHex: "#111111")
}

/// Where a tape strip's path actually lies on the page.
private func pagePath(of element: PageElement) -> [CGPoint] {
    element.points.map { CGPoint(x: $0.x + element.x, y: $0.y + element.y) }
}

// MARK: - Moving and resizing (regression)

@Suite("Moving and resizing elements keeps each path in its own space")
struct ElementPathSpaceTests {

    @Test("Moving tape moves the strip as far as the finger went, not twice as far")
    func tapeMovesOnce() {
        let before = tape(at: CGPoint(x: 50, y: 60))
        let after = before.moved(by: CGSize(width: 30, height: -10))
        let expected = pagePath(of: before).map { CGPoint(x: $0.x + 30, y: $0.y - 10) }
        #expect(zip(pagePath(of: after), expected).allSatisfy { near($0, $1) })
        #expect(after.points == before.points, "the path is relative to the frame, so it doesn't move itself")
    }

    @Test("Moving a fill moves its outline, which is in page space")
    func fillMovesOutline() {
        let after = fill().moved(by: CGSize(width: 10, height: 5))
        #expect(after.points.first == PagePoint(x: 110, y: 105))
        #expect(after.x == 110 && after.y == 105)
    }

    @Test("Resizing tape stretches its path with its frame and keeps it on the strip")
    func tapeScalesWithFrame() {
        let before = tape(at: CGPoint(x: 0, y: 0))
        let doubled = CGAffineTransform(scaleX: 2, y: 2)
        let after = before.transformed(by: doubled)
        #expect(after.width == 240 && after.height == 80)
        #expect(after.points == [PagePoint(x: 34, y: 40), PagePoint(x: 206, y: 40)])
    }

    @Test("Resizing a fill takes its outline through the same transform")
    func fillScales() {
        let doubled = CGAffineTransform(scaleX: 2, y: 2)
        let after = fill().transformed(by: doubled)
        #expect(after.points.last == PagePoint(x: 200, y: 300))
    }
}

// MARK: - Turning

@Suite("Turning a lasso selection")
struct SelectionTurnTests {

    @Test("A quarter turn clockwise on screen is +π/2 in the page's y-down space")
    func quarterTurn() {
        let turn = SelectionRotation.turn(
            about: .zero, from: CGPoint(x: 10, y: 0), to: CGPoint(x: 0, y: 10)
        )
        #expect(near(turn, .pi / 2))
    }

    @Test("Turning across the back of the circle doesn't jump a whole revolution")
    func wrapsAcrossPi() {
        let turn = SelectionRotation.turn(
            about: .zero, from: CGPoint(x: -10, y: -1), to: CGPoint(x: -10, y: 1)
        )
        #expect(abs(turn) < 0.3)
    }

    @Test("The turn settles on a 15° step when it comes close, and only then", arguments: [
        (88.0, 90.0, true), (80.0, 80.0, false), (-14.0, -15.0, true), (2.5, 0.0, true), (7.5, 7.5, false)
    ])
    func detents(degrees: Double, expected: Double, settled: Bool) {
        let result = SelectionRotation.detented(CGFloat(degrees * .pi / 180))
        #expect(near(result.angle, CGFloat(expected * .pi / 180)))
        #expect(result.settled == settled)
    }

    @Test("A fill's outline turns exactly, and its frame becomes the box around it")
    func fillTurnsExactly() {
        let element = fill()
        let pivot = CGPoint(x: 150, y: 125)
        let turned = element.rotated(by: .pi / 2, about: pivot)
        // (100, 100) is 50 left of and 25 above the pivot; a quarter turn
        // clockwise puts it 25 right of and 50 above it: (175, 75).
        #expect(near(turned.points[0].cgPoint, CGPoint(x: 175, y: 75)))
        #expect(near(turned.frame.width, 50) && near(turned.frame.height, 100))
        #expect(turned.rotation == 0, "a path turns itself; it is not also turned as a box")
    }

    @Test("Tape's path turns exactly on the page, and stays relative to its new frame")
    func tapeTurnsExactly() {
        let element = tape(at: CGPoint(x: 100, y: 100))
        let pivot = CGPoint(x: 160, y: 120)
        let turned = element.rotated(by: .pi / 2, about: pivot)
        let expected = pagePath(of: element).map { $0.applying(SelectionRotation.transform(.pi / 2, about: pivot)) }
        #expect(zip(pagePath(of: turned), expected).allSatisfy { near($0, $1) })
        #expect(turned.points.allSatisfy { $0.x >= 0 && $0.y >= 0 }, "relative to its own frame")
    }

    @Test("A text box keeps its size, turns about its centre, and travels round the pivot")
    func boxTurns() {
        let element = textBox()
        let pivot = CGPoint(x: 150, y: 150)
        let turned = element.rotated(by: .pi / 2, about: pivot)
        #expect(turned.width == 100 && turned.height == 20)
        #expect(near(CGFloat(turned.rotation), 90))
        // Its centre (150, 110) is 40 above the pivot; a quarter turn
        // clockwise puts it 40 to the right.
        #expect(near(CGPoint(x: turned.frame.midX, y: turned.frame.midY), CGPoint(x: 190, y: 150)))
        #expect(near(turned.coveredBounds.width, 20) && near(turned.coveredBounds.height, 100))
    }

    @Test("Four quarter turns put a box back exactly where it started, at 0°")
    func fullTurnIsIdentity() {
        var element = textBox()
        let pivot = CGPoint(x: 300, y: 40)
        for _ in 0..<4 { element = element.rotated(by: .pi / 2, about: pivot) }
        #expect(element.rotation == 0)
        #expect(near(CGPoint(x: element.x, y: element.y), CGPoint(x: 100, y: 100), 0.0001))
    }
}

// MARK: - Recolouring

@Suite("Recolouring a lasso selection")
struct SelectionRecolourTests {

    @Test("Text, fills, tape and a plot's curve take the colour; photos and files don't", arguments: [
        (PageElement.Kind.text, true), (.fill, true), (.tape, true), (.functionPlot, true),
        (.image, false), (.file, false), (.audio, false), (.link, false), (.codeBlock, false)
    ])
    func whoTakesColour(kind: PageElement.Kind, takes: Bool) {
        let element = PageElement(kind: kind, x: 0, y: 0, width: 10, height: 10)
        let painted = element.recoloured("#FF0000")
        #expect((painted != nil) == takes)
        if kind == .functionPlot { #expect(painted?.textColorHex == "#FF0000") }
        if kind == .text { #expect(painted?.colorHex == "#FF0000") }
    }

    private func stroke(x: CGFloat, ink: PKInk) -> PKStroke {
        let points = (0...4).map { index in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(index) * 5, y: 20), timeOffset: Double(index) * 0.01,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    @Test("Recoloured ink keeps its ink type and transparency, and the selection still holds it")
    func inkRecolour() {
        let highlighter = PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5))
        let drawing = PKDrawing(strokes: [
            stroke(x: 0, ink: PKInk(.pen, color: .black)),
            stroke(x: 50, ink: highlighter)
        ])
        let keysBefore = drawing.strokes.map(StrokeKey.init)
        let painted = LassoInk.recoloured(drawing, at: [1], to: .red)

        #expect(painted.strokes[0].ink.color == drawing.strokes[0].ink.color, "only what was caught")
        #expect(painted.strokes[1].ink.inkType == .marker)
        #expect(near(painted.strokes[1].ink.color.cgColor.alpha, 0.5, 0.01))
        var red: CGFloat = 0
        _ = painted.strokes[1].ink.color.getRed(&red, green: nil, blue: nil, alpha: nil)
        #expect(red > 0.9)
        #expect(painted.strokes.map(StrokeKey.init) == keysBefore)
    }

    @Test("Turning ink re-keys exactly the strokes it turned")
    func inkTurnRekeys() {
        let drawing = PKDrawing(strokes: [
            stroke(x: 0, ink: PKInk(.pen, color: .black)),
            stroke(x: 50, ink: PKInk(.pen, color: .black))
        ])
        let turn = SelectionRotation.transform(.pi / 2, about: CGPoint(x: 60, y: 20))
        let result = LassoInk.transformed(drawing, at: [1], by: turn)
        #expect(result.keys == [StrokeKey(result.drawing.strokes[1])])
        #expect(StrokeKey.indices(of: result.keys, in: result.drawing.strokes) == [1])
        #expect(result.drawing.strokes[0].transform == .identity)
    }
}
