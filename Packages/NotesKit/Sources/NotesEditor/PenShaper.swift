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
/// - **Tip** is folded into the tool's width before drawing, so it needs no work
///   here (see `PenSettings.effectiveWidth`).
///
/// Nothing is rebuilt when the settings ask for no change, so the common case
/// (stability 1, sensitivity at the ink's own default) costs nothing.
enum PenShaper {
    /// PencilKit's own pressure response — the sensitivity value that means
    /// "leave the stroke exactly as the pencil drew it".
    static let neutralSensitivity = 0.5
    /// How far sensitivity has to sit from neutral before a stroke is worth
    /// rebuilding. Anything inside this band reads identically on the page.
    static let sensitivityDeadband = 0.25

    /// Returns a reshaped copy of `stroke`, or nil when the settings are a no-op.
    static func shaped(_ stroke: PKStroke, settings: PenSettings) -> PKStroke? {
        let window = StrokeSmoothing.window(forStability: settings.stability)
        let needsSmoothing = window > 1
        // Sensitivity only needs applying when it pulls FAR from PencilKit's own
        // 1:1 response. The band is deliberately wide: rebuilding a stroke means
        // reassigning the canvas's drawing, and a barely-visible tweak isn't worth
        // that (the default Flow Pen sits at 0.4, so it now costs nothing at all).
        let needsPressure = abs(settings.sensitivity - Self.neutralSensitivity)
            > Self.sensitivityDeadband
        guard needsSmoothing || needsPressure else { return nil }

        let points = Array(stroke.path)
        guard points.count > 2 else { return nil }

        let locations = StrokeSmoothing.smooth(points.map(\.location), window: window)
        let averageSize = mean(of: points.map(\.size))

        let rebuilt: [PKStrokePoint] = points.enumerated().map { index, point in
            let size = needsPressure
                ? blended(point.size, toward: averageSize, sensitivity: settings.sensitivity)
                : point.size
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

    private static func path(of stroke: PKStroke) -> [CGPoint] {
        stroke.path.map { $0.location.applying(stroke.transform) }
    }
}
