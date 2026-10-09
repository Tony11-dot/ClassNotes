import CoreGraphics
import Foundation

/// Moving, scaling, turning and recolouring an element, as the lasso and a
/// finger drag do. Pure, so every kind's rule is pinned by tests.
///
/// Elements carry paths in two different spaces, and that is the whole reason
/// this exists. A FILL's outline is in page space (it was traced from the ink
/// where it lies). A TAPE strip's path is relative to the strip's own frame
/// (`insertTape`), so moving the frame already moves it. Shifting both, which
/// is what the lasso and the drag used to do, put a moved strip of tape twice
/// as far away as the finger went.
extension PageElement {

    /// Whether `points` and `holes` are page coordinates (true) or relative to
    /// the element's own frame (false).
    public var pathIsInPageSpace: Bool { kind == .fill }

    /// The box the element covers on the page, its own turn included.
    public var coveredBounds: CGRect {
        guard rotation != 0, kind != .fill else { return frame }
        let turn = SelectionRotation.transform(
            CGFloat(rotation * .pi / 180), about: CGPoint(x: frame.midX, y: frame.midY)
        )
        return frame.applying(turn)
    }

    /// The element shifted by `offset`, path and all.
    public func moved(by offset: CGSize) -> PageElement {
        var moved = self
        moved.x += offset.width
        moved.y += offset.height
        if pathIsInPageSpace {
            moved.points = points.map { PagePoint(x: $0.x + offset.width, y: $0.y + offset.height) }
            moved.holes = holes.map { ring in
                ring.map { PagePoint(x: $0.x + offset.width, y: $0.y + offset.height) }
            }
        }
        return moved
    }

    /// The element with its frame mapped through `transform`, a scale and a
    /// shift (the lasso's resize). A page-space path goes through the same
    /// transform; a frame-relative one only scales with its frame.
    public func transformed(by transform: CGAffineTransform) -> PageElement {
        var changed = self
        let newFrame = frame.applying(transform)
        changed.x = newFrame.minX
        changed.y = newFrame.minY
        changed.width = newFrame.width
        changed.height = newFrame.height
        if pathIsInPageSpace {
            changed.points = points.map { PagePoint($0.cgPoint.applying(transform)) }
            changed.holes = holes.map { ring in ring.map { PagePoint($0.cgPoint.applying(transform)) } }
        } else if width > 0, height > 0 {
            let sx = newFrame.width / width, sy = newFrame.height / height
            changed.points = points.map { PagePoint(x: $0.x * sx, y: $0.y * sy) }
        }
        return changed
    }

    /// The element turned by `radians` (clockwise on screen) about `pivot`.
    ///
    /// A path turns exactly: a fill's outline and a strip of tape are points,
    /// and the frame becomes the box around where they now lie. Anything drawn
    /// in a box (text, a photo, a plot, rectangle tape) keeps its size, turns
    /// about its own centre by the same angle (`rotation`, which every renderer
    /// applies), and its centre travels round the pivot with the rest of the
    /// selection.
    public func rotated(by radians: CGFloat, about pivot: CGPoint) -> PageElement {
        let turn = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: radians)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        var turned = self
        if pathIsInPageSpace, !points.isEmpty {
            turned.points = points.map { PagePoint($0.cgPoint.applying(turn)) }
            turned.holes = holes.map { ring in ring.map { PagePoint($0.cgPoint.applying(turn)) } }
            let box = Self.bounds(of: turned.points)
            turned.x = box.minX
            turned.y = box.minY
            turned.width = box.width
            turned.height = box.height
            return turned
        }
        if kind == .tape, !points.isEmpty {
            // Relative path → page space, turned, then relative to its new box,
            // padded the way `TapeGeometry.frame` pads a new strip.
            let absolute = points.map { CGPoint(x: $0.x + x, y: $0.y + y).applying(turn) }
            let pad = (strokeWidth ?? TapeGeometry.defaultThickness) / 2 + 2
            let box = Self.bounds(of: absolute.map(PagePoint.init)).insetBy(dx: -pad, dy: -pad)
            turned.x = box.minX
            turned.y = box.minY
            turned.width = box.width
            turned.height = box.height
            turned.points = absolute.map { PagePoint(x: $0.x - box.minX, y: $0.y - box.minY) }
            return turned
        }
        let centre = CGPoint(x: frame.midX, y: frame.midY).applying(turn)
        turned.x = centre.x - width / 2
        turned.y = centre.y - height / 2
        turned.rotation = Self.normalisedDegrees(rotation + Double(radians) * 180 / .pi)
        return turned
    }

    /// The element in `hex`, or nil when it has no colour of its own to
    /// change (a photo, a file, a voice note, a link, a code block's
    /// syntax-coloured text).
    public func recoloured(_ hex: String) -> PageElement? {
        var changed = self
        switch kind {
        case .text, .fill, .tape:
            changed.colorHex = hex
        case .functionPlot:
            // The curve's colour; `colorHex` is the plot's background.
            changed.textColorHex = hex
        case .image, .file, .audio, .link, .codeBlock, .unknown:
            return nil
        }
        return changed
    }

    static func bounds(of points: [PagePoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Degrees in (-180, 180], so turning a box all the way round reads 0
    /// rather than 360.
    static func normalisedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return abs(value) < 1e-9 ? 0 : value
    }
}

/// Turning a lasso selection with its handle.
public enum SelectionRotation {
    /// Steps the turn settles onto, in degrees.
    public static let detentStep: Double = 15
    /// How close (degrees) the turn has to come to a step to settle on it.
    public static let detentPull: Double = 4

    /// How far the handle has been turned about `centre`, in radians
    /// (clockwise on screen is positive, as in the page's y-down space), from
    /// where the drag began to where it is now.
    public static func turn(about centre: CGPoint, from start: CGPoint, to current: CGPoint) -> CGFloat {
        let a = atan2(start.y - centre.y, start.x - centre.x)
        let b = atan2(current.y - centre.y, current.x - centre.x)
        var delta = b - a
        while delta > .pi { delta -= 2 * .pi }
        while delta <= -.pi { delta += 2 * .pi }
        return delta
    }

    /// `radians` settled onto the nearest 15° step when it is within
    /// `detentPull` of one, and whether it did (the haptic fires then).
    /// Square is the angle people aim for; a hand lands a degree or two off.
    public static func detented(_ radians: CGFloat) -> (angle: CGFloat, settled: Bool) {
        let degrees = Double(radians) * 180 / .pi
        let nearest = (degrees / detentStep).rounded() * detentStep
        guard abs(degrees - nearest) <= detentPull else { return (radians, false) }
        return (CGFloat(nearest * .pi / 180), true)
    }

    /// The transform that turns page content by `radians` about `pivot`.
    public static func transform(_ radians: CGFloat, about pivot: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: radians)
            .translatedBy(x: -pivot.x, y: -pivot.y)
    }
}
