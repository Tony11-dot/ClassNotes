import CoreGraphics
import Foundation
import NotesModels
import PencilKit

/// "Scribble to erase" on a live `PKDrawing`.
///
/// The last stroke is tested with `ScribbleDetector`; when it reads as a scrub
/// AND it actually crossed something, it's dropped along with everything it
/// crossed. Everything else is left exactly as drawn — the mode never eats normal
/// handwriting.
enum ScribbleEraser {
    /// The result of applying the gesture, or nil when the last stroke wasn't an
    /// erasing scribble (so the caller leaves the drawing alone).
    static func applying(to drawing: PKDrawing, tolerance: CGFloat = 12) -> PKDrawing? {
        guard let scribble = drawing.strokes.last else { return nil }
        let scrub = path(of: scribble)
        guard ScribbleDetector.isErasureScribble(scrub) else { return nil }

        var erasedSomething = false
        let survivors = drawing.strokes.dropLast().filter { stroke in
            // Cheap reject first: no bounding-box overlap means no crossing.
            guard stroke.renderBounds.intersects(scribble.renderBounds.insetBy(dx: -tolerance, dy: -tolerance))
            else { return true }
            if ScribbleDetector.crosses(scrub, path(of: stroke), tolerance: tolerance) {
                erasedSomething = true
                return false
            }
            return true
        }
        // A scrub over BLANK paper is just writing — a fast "www", a hatch fill, a
        // zigzag arrow. Swallowing it made letters vanish a moment after they were
        // written, so an erase that erases nothing is not an erase.
        guard erasedSomething else { return nil }
        return PKDrawing(strokes: Array(survivors))
    }

    /// A stroke's geometry, densely sampled.
    ///
    /// It must read the SPLINE, not the control points. `PKStrokePath` is fitted:
    /// a fast scrub back and forth over a word is stored as a handful of control
    /// points, and `ScribbleDetector` needs at least eight samples and four
    /// direction reversals before it will call anything an erasure. Measuring the
    /// control points meant a real scrub scored two or three reversals out of a
    /// possible four and the gesture never fired once — the switch was on and
    /// nothing happened.
    private static func path(of stroke: PKStroke) -> [CGPoint] {
        let path = stroke.path
        guard path.count > 1 else {
            return path.map { $0.location.applying(stroke.transform) }
        }
        return path.interpolatedPoints(by: .distance(2))
            .map { $0.location.applying(stroke.transform) }
    }
}
