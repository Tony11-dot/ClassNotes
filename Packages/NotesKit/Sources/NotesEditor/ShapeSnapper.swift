import CoreGraphics
import Foundation
import PencilKit

/// Snaps a freehand stroke to a clean geometric shape when the user "holds" the
/// pencil at the end of the stroke — the same gesture as Apple Notes. The hold is
/// read from the stroke's own timing, then the path is fitted to a line, angle,
/// ellipse, rectangle, triangle or pentagon, preserving the ink.
enum ShapeSnapper {
    /// How long the pencil must rest at the end of a stroke for it to count as
    /// "hold to snap". Kept a beat above the live watcher's own
    /// `StrokeDwellRecognizer.minimumHold` (0.45s) — this is the safety net for
    /// a stroke the live path missed entirely, not a second, more permissive
    /// chance at the same stroke it already turned down.
    static let minimumHold: TimeInterval = 0.55
    /// How far the pencil may drift during that rest and still be holding still,
    /// in SCREEN terms (the live watcher divides this back into whatever the
    /// page's own logical space needs — see `StrokeDwellRecognizer.holdRadius`).
    /// Generous, because a hand resting on glass is never actually still —
    /// 14 still asked for more precision than a relaxed hold gives.
    static let holdRadius: CGFloat = 22
    /// How far the ink may wander off the straight line between its endpoints and
    /// still be snapped to that line. A deliberate hold is a statement of intent,
    /// so this is looser than a passive straightness test would be — but not so
    /// loose that a drawn arc collapses into a chord.
    static let straightTolerance: CGFloat = 0.15

    /// Converts the user-facing `snapTolerance` setting — a constant SCREEN
    /// distance — into the logical/page-space radius the fitter actually
    /// operates on, by dividing out the current zoom. Both the live preview
    /// (`CanvasSnapPreview.previewSnap`) and the release-only fallback below
    /// call this, so a tolerance change feels identical on either path. Left
    /// unconverted (as it was before this existed), the fitter's effective
    /// tolerance drifted with zoom — too tight zoomed out, too loose zoomed
    /// in — which alone was enough to make a genuine hold fail to fit.
    static func holdRadius(forTolerance tolerance: CGFloat, zoomScale: CGFloat) -> CGFloat {
        tolerance / max(zoomScale, 0.01)
    }

    /// If `stroke` ends with a dwell and fits a primitive confidently, returns a
    /// replacement stroke; otherwise nil (leave the freehand stroke as drawn).
    ///
    /// This is the FALLBACK path, used when the live dwell watcher didn't catch
    /// the hold — the snap normally settles under the pencil while it's still
    /// down (see `StrokeDwellRecognizer`).
    ///
    /// `holdRadius` defaults to the constant above but is overridable so this
    /// path stays in step with the user's own snap-tolerance setting.
    static func snapped(_ stroke: PKStroke, holdRadius: CGFloat = holdRadius) -> PKStroke? {
        guard holdDuration(of: stroke, holdRadius: holdRadius) >= minimumHold else { return nil }
        let points = trimmedTail(densePoints(stroke), holdRadius: holdRadius)
        guard points.count >= 6, let path = fit(points) else { return nil }
        return rebuild(stroke, along: path)
    }

    // MARK: - Live, adjustable snapping

    /// The kind of shape a stroke settled into. Kept apart from the points it was
    /// fitted from so the SAME shape can be redrawn at a new size or angle while
    /// the pencil is still down.
    enum Shape: Equatable {
        case line
        /// A single deliberate bend, at a fraction along the way to the handle.
        case angle(bendAt: CGPoint)
        case ellipse
        case rectangle
        /// Apex position across the box, 0…1 — so a leaning triangle keeps leaning
        /// as it's resized.
        case triangle(apexFraction: CGFloat)
        case polygon(sides: Int)

        var isClosed: Bool {
            switch self {
            case .line, .angle: false
            default: true
            }
        }
    }

    /// A shape that has settled under a pencil which is STILL DOWN: the corner or
    /// end that stays put, and the one the pencil now holds.
    ///
    /// This is what makes a snap feel like a tool rather than a verdict. Snapping
    /// on release means the only way to change a circle's size is to undo it and
    /// draw again; here the pencil keeps the far end, so length, direction and size
    /// are still yours until you lift.
    struct LiveSnap: Equatable {
        var shape: Shape
        /// Fixed while the pencil drags.
        var anchor: CGPoint
        /// Where the pencil is; moving it redraws the shape.
        var handle: CGPoint
    }

    /// Classifies an in-progress path and works out which end the pencil holds.
    static func liveSnap(_ points: [CGPoint], holdRadius: CGFloat = holdRadius) -> LiveSnap? {
        let trimmed = trimmedTail(points, holdRadius: holdRadius)
        guard trimmed.count >= 6, let (shape, box) = classify(trimmed),
              let start = trimmed.first, let rest = trimmed.last else { return nil }

        guard shape.isClosed else {
            return LiveSnap(shape: shape, anchor: start, handle: rest)
        }
        // A closed shape is sized by its box, so the pencil takes the corner
        // nearest where it stopped and the opposite corner stays put.
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)
        ]
        let handle = corners.min { distance($0, rest) < distance($1, rest) } ?? corners[2]
        let anchor = CGPoint(
            x: handle.x == box.minX ? box.maxX : box.minX,
            y: handle.y == box.minY ? box.maxY : box.minY
        )
        return LiveSnap(shape: shape, anchor: anchor, handle: handle)
    }

    /// How near a line has to come to level or upright before it clicks onto it.
    static let detentAngle: CGFloat = .pi / 180 * 4
    /// Where the detent starts PULLING. Between this and `detentAngle` the free
    /// end is eased toward the axis instead of following the pencil exactly, so
    /// the line resists being taken off level — the same feel as a straight-edge
    /// under the hand. Without it a detent is a cliff: dead until it grabs.
    static let detentPull: CGFloat = .pi / 180 * 13

    /// A held line's free end, pulled onto the horizontal or the vertical when it
    /// comes close — the reason you can rule a straight edge freehand.
    ///
    /// Returns whether it landed on a detent as well as where, so the caller can
    /// tap the user's hand as it clicks in. The length is preserved: the line
    /// straightens, it doesn't also shorten.
    static func detented(_ handle: CGPoint, from anchor: CGPoint) -> (point: CGPoint, isDetent: Bool) {
        let dx = handle.x - anchor.x
        let dy = handle.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 6 else { return (handle, false) }
        let angle = atan2(dy, dx)
        // Distance to the nearer of level (0 / π) and upright (±π/2).
        let quarter = CGFloat.pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        let offset = angle - nearest
        guard abs(offset) <= detentPull else { return (handle, false) }

        func point(at radians: CGFloat) -> CGPoint {
            CGPoint(x: anchor.x + cos(radians) * length, y: anchor.y + sin(radians) * length)
        }
        guard abs(offset) > detentAngle else { return (point(at: nearest), true) }
        // In the magnet's reach but not on it: ease back toward the axis. At the
        // outer edge the pencil is followed exactly; near the axis most of the
        // movement is absorbed, which is what "resistance" feels like.
        let travel = (abs(offset) - detentAngle) / (detentPull - detentAngle)
        let eased = detentAngle + (detentPull - detentAngle) * travel * travel
        return (point(at: nearest + (offset < 0 ? -eased : eased)), false)
    }

    /// How near a closed shape's box has to come to square before it clicks
    /// square — which is also what turns an ellipse into a circle.
    static let squareTolerance: CGFloat = 0.09

    /// A box pulled square when it is nearly square, keeping `anchor`'s corner
    /// where it is. The circle you meant to draw is a circle; the rectangle you
    /// meant as a square is a square.
    static func squared(
        _ box: CGRect, anchoredAt anchor: CGPoint
    ) -> (box: CGRect, isDetent: Bool) {
        let longest = max(box.width, box.height)
        guard longest > 8 else { return (box, false) }
        guard abs(box.width - box.height) / longest <= squareTolerance else { return (box, false) }
        let side = (box.width + box.height) / 2
        return (
            CGRect(
                x: anchor.x <= box.midX ? anchor.x : anchor.x - side,
                y: anchor.y <= box.midY ? anchor.y : anchor.y - side,
                width: side, height: side
            ),
            true
        )
    }

    /// The snap redrawn with the pencil somewhere new. Returns nil once the shape
    /// has been dragged down to nothing, so a stray flick can't collapse it.
    static func path(for snap: LiveSnap, handle: CGPoint) -> [CGPoint]? {
        resolve(snap, handle: handle)?.path
    }

    /// The snap redrawn, and whether it landed on one of the assists — level,
    /// upright, or square. The caller taps the user's hand when it does, so a
    /// perfect edge is something you can feel for rather than squint at.
    static func resolve(
        _ snap: LiveSnap, handle: CGPoint
    ) -> (path: [CGPoint], isDetent: Bool)? {
        let anchor = snap.anchor
        switch snap.shape {
        case .line:
            guard distance(anchor, handle) > 6 else { return nil }
            let settled = detented(handle, from: anchor)
            return ([anchor, settled.point], settled.isDetent)
        case .angle(let bend):
            guard distance(anchor, handle) > 6 else { return nil }
            return (densify([anchor, bend, handle]), false)
        default:
            let drawn = CGRect(
                x: min(anchor.x, handle.x), y: min(anchor.y, handle.y),
                width: abs(handle.x - anchor.x), height: abs(handle.y - anchor.y)
            )
            guard drawn.width > 8, drawn.height > 8 else { return nil }
            let settled = squared(drawn, anchoredAt: anchor)
            return (path(for: snap.shape, in: settled.box), settled.isDetent)
        }
    }

    /// Rebuilds `original` along an already-fitted path — the commit half of the
    /// live snap, so the preview and the ink can't disagree.
    static func stroke(from path: [CGPoint], like original: PKStroke) -> PKStroke {
        rebuild(original, along: path)
    }

    /// A snapped shape with no drawn stroke to copy. Once the live preview takes
    /// the wandering ink off the page there may be nothing left to rebuild from,
    /// so the shape is inked from the tool that was in hand instead.
    static func stroke(from path: [CGPoint], ink: PKInk, width: CGFloat) -> PKStroke {
        let size = CGSize(width: max(width, 1), height: max(width, 1))
        let controlPoints = path.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.01,
                size: size,
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: shapeSafeInk(ink),
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        )
    }

    /// Substitutes a shape-safe ink for one whose hand-built `PKStroke` has been
    /// traced, on real hardware, to real and repeatable ink loss.
    ///
    /// Every commit path in this file treats every ink identically — there is
    /// no branch anywhere that singles one out — and yet only the two
    /// `.monoline` presets (Flow Pen, Fineliner) ever lost a settled shape;
    /// every other ink held on every test. A difference that consistent with
    /// nothing in this file to produce it has to live in PencilKit's own
    /// renderer for a `PKStroke` assembled by hand rather than drawn through
    /// its own gesture pipeline. Rather than keep chasing a closed-source
    /// implementation detail with no way to inspect it, a shape inked with
    /// `.monoline` is built as `.pen` instead. Every hand-built shape stroke
    /// already carries a flat, non-varying `force` (see `stroke(from:ink:width:)`
    /// and `rebuild(_:along:)`), so `.pen`'s own pressure-reactive width has
    /// nothing to react to and draws the same constant-width line `.monoline`
    /// would have — the swap changes nothing you can see on a settled shape,
    /// only whether it's still there afterward. Ordinary handwriting with
    /// either pen is untouched; this only ever applies to a shape's own ink.
    static func shapeSafeInk(_ ink: PKInk) -> PKInk {
        ink.inkType == .monoline ? PKInk(.pen, color: ink.color) : ink
    }

    // MARK: - Hold detection

    /// How long the pencil stayed put at the end of the stroke.
    ///
    /// Measured as the time since it was last farther than `holdRadius` from where
    /// it came to rest — NOT as the time spanned by the points inside a fixed
    /// trailing window.
    ///
    /// That distinction is the whole feature. `PKStrokePath` stores a FITTED
    /// spline, not the raw touch stream: a pencil held still needs no new control
    /// points, so PencilKit collapses a half-second dwell into a single point whose
    /// `timeOffset` simply jumps. A window scan then sees one point, measures a
    /// zero-length hold, and refuses every snap — which is exactly what shipped.
    ///
    /// Returns 0 for a stroke that never left `holdRadius` at all: that's a dot
    /// being placed, not a shape being drawn.
    static func holdDuration(of stroke: PKStroke, holdRadius: CGFloat = holdRadius) -> TimeInterval {
        let points = Array(stroke.path)
        guard let last = points.last else { return 0 }
        for point in points.reversed() where distance(point.location, last.location) > holdRadius {
            return max(0, last.timeOffset - point.timeOffset)
        }
        return 0
    }

    // MARK: - Sampling

    /// The stroke's geometry, densely and evenly sampled.
    ///
    /// Fitting has to read the spline, not its control points: a quick straight
    /// line can be four control points, and the old six-point floor threw those
    /// strokes away before they were ever looked at.
    static func densePoints(_ stroke: PKStroke) -> [CGPoint] {
        let path = stroke.path
        guard path.count > 1 else { return path.map(\.location) }
        return path.interpolatedPoints(by: .distance(2)).map(\.location)
    }

    /// Drops the dwell from the end of the path so the pause doesn't drag the fit
    /// toward the resting point, while keeping the true endpoint.
    static func trimmedTail(_ points: [CGPoint], holdRadius: CGFloat = holdRadius) -> [CGPoint] {
        guard let last = points.last,
              let cut = points.lastIndex(where: { distance($0, last) > holdRadius }),
              cut < points.count - 1
        else { return points }
        return Array(points[0...cut]) + [last]
    }
}
