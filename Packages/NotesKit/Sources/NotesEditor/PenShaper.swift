import CoreGraphics
import Foundation
import NotesModels
import PencilKit

/// Applies a pen's tuning to a finished stroke.
///
/// PencilKit gives us an ink family, a color and a nominal width — it has no API
/// for "smooth this line" or "respond less to pressure". So the sliders in a pen's
/// settings panel are applied here, by rebuilding the stroke's control points once
/// it's complete:
///
/// - **Stability** averages the path (see `StrokeSmoothing`), straightening tremor.
/// - **Sensitivity** scales how far pressure moves the point size: 0 gives a
///   perfectly even line, 1 gives the full pressure range.
/// - **Tip** tapers the stroke's ends: a pointed tip enters and leaves the paper
///   on its point, a blunt one lays full width from the first point to the last.
///
/// Every slider in the panel lands in one of those three places or in the tool
/// itself (thickness → width, concentration → alpha, colour → colour). A setting
/// that changed nothing on the page would be a lie about what the pen does, so
/// there isn't one.
///
/// Nothing is rebuilt when the settings ask for no change, so a pen left at
/// stability 1, neutral sensitivity and a blunt tip costs nothing at all.
enum PenShaper {
    /// PencilKit's own pressure response — the sensitivity value that means
    /// "leave the stroke exactly as the pencil drew it".
    static let neutralSensitivity = 0.5
    /// How far sensitivity has to sit from neutral to be worth rebuilding for.
    /// Small enough that any deliberate move of the slider shows up: a wide band
    /// (this was 0.25) means half the slider's travel does nothing, which is
    /// indistinguishable from a broken control.
    static let sensitivityDeadband = 0.02

    /// Returns a reshaped copy of `stroke`, or nil when the settings are a no-op.
    static func shaped(_ stroke: PKStroke, settings: PenSettings) -> PKStroke? {
        let window = StrokeSmoothing.window(forStability: settings.stability)
        let needsSmoothing = window > 1
        let needsPressure = abs(settings.sensitivity - Self.neutralSensitivity)
            > Self.sensitivityDeadband
        let needsTaper = settings.tapersEnds
        guard needsSmoothing || needsPressure || needsTaper else { return nil }

        let points = Array(stroke.path)
        guard points.count > 2 else { return nil }

        let locations = StrokeSmoothing.smooth(points.map(\.location), window: window)
        let averageSize = mean(of: points.map(\.size))

        let rebuilt: [PKStrokePoint] = points.enumerated().map { index, point in
            var size = needsPressure
                ? blended(point.size, toward: averageSize, sensitivity: settings.sensitivity)
                : point.size
            if needsTaper {
                let factor = taper(at: index, of: points.count, tip: settings.tip)
                size = CGSize(width: size.width * factor, height: size.height * factor)
            }
            return PKStrokePoint(
                location: index < locations.count ? locations[index] : point.location,
                timeOffset: point.timeOffset,
                size: size,
                opacity: point.opacity,
                force: point.force,
                azimuth: point.azimuth,
                altitude: point.altitude
            )
        }
        let path = PKStrokePath(controlPoints: rebuilt, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
    }

    /// How much of its width the stroke lays down at `index`.
    ///
    /// A pointed tip narrows the stroke over a run-in at each end and is at full
    /// width everywhere between. Both the length of that run-in and how thin the
    /// very end gets follow the Tip slider, so the difference between a ball and a
    /// brush is visible in a single downstroke.
    static func taper(at index: Int, of count: Int, tip: Double) -> CGFloat {
        guard count > 2, tip > 0 else { return 1 }
        let span = max(1.0, Double(count - 1) * min(0.3, tip * 0.32))
        let fromStart = Double(index)
        let fromEnd = Double(count - 1 - index)
        let distance = min(fromStart, fromEnd)
        guard distance < span else { return 1 }
        // Thinnest at the very tip, full width by the end of the run-in.
        let narrowest = 1 - tip * 0.85
        return CGFloat(narrowest + (1 - narrowest) * (distance / span))
    }

    /// Pulls a point's size toward the stroke's average as sensitivity drops.
    /// `sensitivity == 0.5` is neutral (PencilKit's own response), 0 flattens the
    /// line completely, 1 exaggerates the pressure difference.
    private static func blended(
        _ size: CGSize, toward average: CGSize, sensitivity: Double
    ) -> CGSize {
        let factor = CGFloat(sensitivity / 0.5)
        return CGSize(
            width: max(0.1, average.width + (size.width - average.width) * factor),
            height: max(0.1, average.height + (size.height - average.height) * factor)
        )
    }

    private static func mean(of sizes: [CGSize]) -> CGSize {
        guard !sizes.isEmpty else { return CGSize(width: 1, height: 1) }
        var width: CGFloat = 0
        var height: CGFloat = 0
        for size in sizes {
            width += size.width
            height += size.height
        }
        let count = CGFloat(sizes.count)
        return CGSize(width: width / count, height: height / count)
    }
}

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
