import CoreGraphics
import Foundation
import PencilKit
import Testing
import UIKit
@testable import NotesEditor
import NotesModels

@Suite("Lasso thickness")
struct LassoThicknessTests {

    private func stroke(y: CGFloat, width: CGFloat, created: Date = Date()) -> PKStroke {
        let points = (0..<12).map { index in
            PKStrokePoint(
                location: CGPoint(x: 10 + CGFloat(index) * 8, y: y + CGFloat(index % 3)),
                timeOffset: TimeInterval(index) * 0.01,
                size: CGSize(width: width, height: width), opacity: 1, force: 0.7,
                azimuth: 0.3, altitude: 1.1
            )
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: created))
    }

    @Test("Thicker changes only the caught strokes' width, and nothing about where they are")
    func thickensOnlyWidth() {
        let drawing = PKDrawing(strokes: [stroke(y: 10, width: 2), stroke(y: 60, width: 2)])
        let thick = LassoInk.rethickened(drawing, at: [1], by: 1.5)

        #expect(thick.strokes[0].path.map(\.size) == drawing.strokes[0].path.map(\.size), "not caught: untouched")
        #expect(thick.strokes[1].path.allSatisfy { abs($0.size.width - 3) < 0.0001 })
        #expect(thick.strokes[1].path.map(\.location) == drawing.strokes[1].path.map(\.location))
        #expect(thick.strokes[1].path.map(\.force) == drawing.strokes[1].path.map(\.force))
        #expect(thick.strokes[1].ink.inkType == .pen)
    }

    @Test("The selection still holds the strokes after a thickness change (keys unchanged)")
    func keysHold() {
        let drawing = PKDrawing(strokes: [stroke(y: 10, width: 2), stroke(y: 60, width: 2)])
        let keys = drawing.strokes.map(StrokeKey.init)
        let thick = LassoInk.rethickened(drawing, at: [0, 1], by: 1.3)
        #expect(StrokeKey.indices(of: keys, in: thick.strokes) == [0, 1])
    }

    @Test("Thinner exactly undoes Thicker, and width stays inside its limits")
    func roundTripAndLimits() {
        let drawing = PKDrawing(strokes: [stroke(y: 10, width: 4)])
        let back = LassoInk.rethickened(
            LassoInk.rethickened(drawing, at: [0], by: LassoSelectionView.thicker),
            at: [0], by: LassoSelectionView.thinner
        )
        #expect(back.strokes[0].path.allSatisfy { abs($0.size.width - 4) < 0.0001 })

        var tiny = drawing
        for _ in 0..<40 { tiny = LassoInk.rethickened(tiny, at: [0], by: 0.5) }
        #expect(tiny.strokes[0].path.allSatisfy { $0.size.width >= LassoInk.thicknessRange.lowerBound },
                "a line never thins to nothing")
        var huge = drawing
        for _ in 0..<40 { huge = LassoInk.rethickened(huge, at: [0], by: 2) }
        #expect(huge.strokes[0].path.allSatisfy { $0.size.width <= LassoInk.thicknessRange.upperBound })
    }

    @Test("A factor of zero or less changes nothing")
    func nonsense() {
        let drawing = PKDrawing(strokes: [stroke(y: 10, width: 4)])
        #expect(LassoInk.rethickened(drawing, at: [0], by: 0).dataRepresentation() == drawing.dataRepresentation())
    }
}
