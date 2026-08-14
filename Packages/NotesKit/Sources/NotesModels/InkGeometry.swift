import CoreGraphics
import Foundation

/// Path smoothing behind the pen's "Stability" slider.
///
/// Stability 1 leaves the pencil's own path alone; higher values average each
/// point against its neighbours, which straightens the tremor out of a slow line
/// without shortening it (endpoints are pinned).
public enum StrokeSmoothing {
    /// The averaging window for a stability step. 1 → 1 (identity).
    public static func window(forStability stability: Int) -> Int {
        let clamped = min(max(stability, PenSettings.stabilityRange.lowerBound),
                          PenSettings.stabilityRange.upperBound)
        return clamped * 2 - 1
    }

    /// Moving-average smoothing with pinned endpoints. Returns `points` unchanged
    /// for a window of 1 or a path too short to average.
    public static func smooth(_ points: [CGPoint], window: Int) -> [CGPoint] {
        guard window > 1, points.count > 2 else { return points }
        let half = window / 2
        var result = points
        for index in 1..<(points.count - 1) {
            let lower = max(0, index - half)
            let upper = min(points.count - 1, index + half)
            var sumX: CGFloat = 0
            var sumY: CGFloat = 0
            for j in lower...upper {
                sumX += points[j].x
                sumY += points[j].y
            }
            let count = CGFloat(upper - lower + 1)
            result[index] = CGPoint(x: sumX / count, y: sumY / count)
        }
        return result
    }

    public static func smooth(_ points: [CGPoint], stability: Int) -> [CGPoint] {
        smooth(points, window: window(forStability: stability))
    }
}

/// "Scribble to erase": when the mode is on, a quick back-and-forth scrub is
/// treated as an erase gesture instead of a stroke, and every stroke it crosses
/// is removed along with the scribble itself.
///
/// The test is deliberately conservative — a scribble has to reverse direction
/// several times *and* fold back over its own bounding box — so ordinary
/// handwriting (an `m`, a `w`, a crossed `t`) is never mistaken for one.
public enum ScribbleDetector {
    /// Minimum direction reversals along the dominant axis.
    public static let minimumReversals = 4
    /// Minimum path length relative to the bounding box's diagonal.
    public static let minimumFoldRatio: CGFloat = 2.6

    public static func isErasureScribble(_ points: [CGPoint]) -> Bool {
        guard points.count >= 8 else { return false }
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 24 else { return false }
        let length = pathLength(points)
        guard length / diagonal >= minimumFoldRatio else { return false }
        return reversals(points, horizontal: box.width >= box.height) >= minimumReversals
    }

    /// Counts sign changes of travel along the dominant axis, ignoring jitter
    /// below a few points of movement.
    public static func reversals(_ points: [CGPoint], horizontal: Bool) -> Int {
        var count = 0
        var lastSign = 0
        var accumulated: CGFloat = 0
        for index in 1..<points.count {
            let delta = horizontal
                ? points[index].x - points[index - 1].x
                : points[index].y - points[index - 1].y
            accumulated += delta
            guard abs(accumulated) > 6 else { continue }
            let sign = accumulated > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign { count += 1 }
            lastSign = sign
            accumulated = 0
        }
        return count
    }

    /// True when any sampled point of `path` comes within `tolerance` of any
    /// sampled point of `other` — the "did the scrub cross this stroke" test.
    public static func crosses(_ path: [CGPoint], _ other: [CGPoint], tolerance: CGFloat) -> Bool {
        guard !path.isEmpty, !other.isEmpty else { return false }
        let toleranceSquared = tolerance * tolerance
        // Sample both paths so a very long stroke doesn't make this quadratic-slow.
        let scrub = sampled(path, maximum: 96)
        let target = sampled(other, maximum: 96)
        for point in scrub {
            for candidate in target {
                let dx = point.x - candidate.x
                let dy = point.y - candidate.y
                if dx * dx + dy * dy <= toleranceSquared { return true }
            }
        }
        return false
    }

    private static func sampled(_ points: [CGPoint], maximum: Int) -> [CGPoint] {
        guard points.count > maximum else { return points }
        let step = points.count / maximum
        return points.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    public static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return total
    }

    public static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The straight-edge, as geometry: where it lies on the page and what it does to
/// a stroke drawn along it.
///
/// A ruler you can only look at is a decoration. A real one is a wall — you run
/// the pen down its edge and the line comes out straight however much your hand
/// wanders. That is what this does: ink drawn along either long edge is projected
/// onto that edge, so the stroke is exactly as straight as the ruler is.
///
/// Pure so the rule can be tested without a canvas; the editor's only job is to
/// say where the ruler is in the page's own logical space.
public struct RulerGuide: Sendable, Equatable {
    /// The ruler's centre line, in page-logical points.
    public var start: CGPoint
    public var end: CGPoint
    /// Half the ruler's width — the distance from the centre line to either edge.
    public var halfWidth: CGFloat

    public init(start: CGPoint, end: CGPoint, halfWidth: CGFloat) {
        self.start = start
        self.end = end
        self.halfWidth = halfWidth
    }

    /// How far from an edge ink may be drawn and still be guided by it. Wide
    /// enough that a hand resting against the ruler is caught, narrow enough that
    /// writing further down the page is left alone.
    public static let snapBand: CGFloat = 30
    /// How much longer along the edge than across it a stroke has to be before it
    /// counts as "drawn along the ruler" rather than merely near it.
    public static let minimumAspect: CGFloat = 2.2
    /// Shorter than this and there is no direction to speak of.
    public static let minimumLength: CGFloat = 12

    /// The two long edges of the ruler, as centre-line offsets along its normal.
    public var edges: [(start: CGPoint, end: CGPoint)] {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return [] }
        let normal = CGVector(dx: -dy / length, dy: dx / length)
        return [halfWidth, -halfWidth].map { offset in
            (
                CGPoint(x: start.x + normal.dx * offset, y: start.y + normal.dy * offset),
                CGPoint(x: end.x + normal.dx * offset, y: end.y + normal.dy * offset)
            )
        }
    }

    /// `points` projected onto whichever edge they were drawn along, or nil when
    /// the stroke wasn't drawn against the ruler at all.
    ///
    /// The result is the two ends of the straightened run: every sample is
    /// projected onto the edge's infinite line, and the extremes of those
    /// projections are the line the user actually meant to draw.
    public func straightened(_ points: [CGPoint]) -> [CGPoint]? {
        guard points.count >= 2 else { return nil }
        var best: (edge: (start: CGPoint, end: CGPoint), distance: CGFloat)?
        for edge in edges {
            let mean = meanDistance(points, from: edge)
            if best == nil || mean < best!.distance { best = (edge, mean) }
        }
        guard let chosen = best, chosen.distance <= Self.snapBand else { return nil }

        let axis = CGVector(
            dx: chosen.edge.end.x - chosen.edge.start.x,
            dy: chosen.edge.end.y - chosen.edge.start.y
        )
        let length = hypot(axis.dx, axis.dy)
        guard length > 0.0001 else { return nil }
        let unit = CGVector(dx: axis.dx / length, dy: axis.dy / length)

        var lowest = CGFloat.greatestFiniteMagnitude
        var highest = -CGFloat.greatestFiniteMagnitude
        var widest: CGFloat = 0
        for point in points {
            let dx = point.x - chosen.edge.start.x
            let dy = point.y - chosen.edge.start.y
            let along = dx * unit.dx + dy * unit.dy
            lowest = min(lowest, along)
            highest = max(highest, along)
            widest = max(widest, abs(dx * -unit.dy + dy * unit.dx))
        }
        let span = highest - lowest
        guard span >= Self.minimumLength else { return nil }
        // Near the ruler but drawn ACROSS it (a tick, a crossed t) is not a line
        // being ruled, and straightening it would flatten it into the edge.
        guard span >= widest * Self.minimumAspect else { return nil }

        func point(at along: CGFloat) -> CGPoint {
            CGPoint(
                x: chosen.edge.start.x + unit.dx * along,
                y: chosen.edge.start.y + unit.dy * along
            )
        }
        // Drawn right-to-left? Keep the direction the hand went, so the stroke's
        // taper and pressure profile still run the way it was drawn.
        let forward = points[points.count - 1].x * unit.dx + points[points.count - 1].y * unit.dy
            >= points[0].x * unit.dx + points[0].y * unit.dy
        return forward
            ? [point(at: lowest), point(at: highest)]
            : [point(at: highest), point(at: lowest)]
    }

    private func meanDistance(_ points: [CGPoint], from edge: (start: CGPoint, end: CGPoint)) -> CGFloat {
        let dx = edge.end.x - edge.start.x, dy = edge.end.y - edge.start.y
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return .greatestFiniteMagnitude }
        var total: CGFloat = 0
        for point in points {
            total += abs(
                dy * point.x - dx * point.y + edge.end.x * edge.start.y - edge.end.y * edge.start.x
            ) / length
        }
        return total / CGFloat(points.count)
    }
}

/// Groups stroke bounding boxes into lines of writing — the unit real-time
/// beautification recognizes and replaces. Pure geometry so it can be tested
/// without a canvas.
public enum LineGrouper {
    /// Groups indices of `boxes` into lines, top-to-bottom, each line's members
    /// ordered left-to-right. Two boxes share a line when they overlap vertically
    /// by more than `overlap` of the shorter box.
    public static func lines(of boxes: [CGRect], overlap: CGFloat = 0.4) -> [[Int]] {
        let ordered = boxes.enumerated()
            .filter { !$0.element.isNull && $0.element.height > 0 }
            .sorted { $0.element.midY < $1.element.midY }
        var groups: [[Int]] = []
        var bands: [CGRect] = []

        for (index, box) in ordered {
            if let match = bands.indices.first(where: { shareLine(bands[$0], box, overlap: overlap) }) {
                groups[match].append(index)
                bands[match] = bands[match].union(box)
            } else {
                groups.append([index])
                bands.append(box)
            }
        }

        // Sort members left-to-right, then lines top-to-bottom by their band.
        let sorted = zip(groups, bands)
            .map { group, band in (group.sorted { boxes[$0].minX < boxes[$1].minX }, band) }
            .sorted { $0.1.midY < $1.1.midY }
        return sorted.map(\.0)
    }

    static func shareLine(_ band: CGRect, _ box: CGRect, overlap: CGFloat) -> Bool {
        let top = max(band.minY, box.minY)
        let bottom = min(band.maxY, box.maxY)
        let shared = bottom - top
        guard shared > 0 else { return false }
        return shared >= min(band.height, box.height) * overlap
    }
}

/// How a face measures — injected so layout stays pure and testable, while the
/// real numbers come from the actual font (`FontResolver`).
///
/// Beautification used to estimate a run's width as `characters × size × 0.58`.
/// That single constant is wrong for every face by a different amount, and it is
/// why the type never matched the settings: too narrow and the run wrapped inside
/// a box only one line tall, so the second half was CLIPPED and the size looked
/// ignored; too wide and the box drifted away from the writing it replaced.
public struct TextMetrics: Sendable {
    /// Width of `text` set on ONE line at `typeSize`.
    public let width: @Sendable (String, Double) -> Double
    /// Height of one line of type at `typeSize` (ascent + descent + leading).
    public let lineHeight: @Sendable (Double) -> Double

    public init(
        width: @escaping @Sendable (String, Double) -> Double,
        lineHeight: @escaping @Sendable (Double) -> Double
    ) {
        self.width = width
        self.lineHeight = lineHeight
    }

    /// A face-agnostic approximation. Only for callers with no font at hand —
    /// anything that draws should measure the real one.
    public static let nominal = TextMetrics(
        width: { text, size in Double(max(text.count, 1)) * size * 0.55 },
        lineHeight: { size in size * 1.2 }
    )
}

/// Where a beautified line of text goes, and when new writing should join a line
/// that was already typeset. Pure so the placement rules are pinned by tests.
public enum BeautifyLayout {
    /// The padding `PageContentView` / `PageElementsLayer` draw text inside, on
    /// every edge. The box has to carry it or the last word is cut off.
    public static let textInset: Double = 6

    /// The frame for a run of typeset text replacing handwriting in `inkBounds`,
    /// measured in the face and size it will actually be drawn in — so the box is
    /// exactly as tall as the settings say, and as wide as the words need.
    public static func frame(
        inkBounds: CGRect,
        text: String,
        typeSize: Double,
        lineSpacing: Double,
        metrics: TextMetrics,
        in pageSize: CGSize,
        minimumWidth: Double = 0
    ) -> CGRect {
        let inset = textInset * 2
        let line = metrics.lineHeight(typeSize)
        let leading = max(lineSpacing, 0.5)

        let x = min(max(Double(inkBounds.minX), 8), max(8, Double(pageSize.width) - 48))
        let available = max(Double(pageSize.width) - x - 8, 48)
        let measured = metrics.width(text, typeSize) + inset + 2
        // A run never gets NARROWER than it already was: it may have been laid out
        // in another face or at another size, and shrinking it around today's
        // measurement would cut yesterday's words off.
        let width = min(max(max(measured, minimumWidth), 32), available)

        // Long enough to wrap? Then the box has to be tall enough for the wraps,
        // or the run is silently cut in half.
        let usable = max(width - inset, 1)
        let lines = max(1, Int(ceil((measured - inset) / usable)))
        let height = line * leading * Double(lines) + inset

        // Center the type band on the handwriting's visual middle.
        let y = min(
            max(Double(inkBounds.midY) - height / 2, 4),
            max(4, Double(pageSize.height) - height - 4)
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// True when a freshly recognized line belongs to an existing typeset run —
    /// the student kept writing on the same line, so the words should be appended
    /// rather than dropped on top as a second box.
    ///
    /// Both rectangles are the INK's, never the type's. Typeset words are far
    /// narrower than the handwriting they replace, so measuring the gap from the
    /// text box makes a hand that carried straight on across the page look like it
    /// started somewhere new.
    public static func continues(
        existing: CGRect, incoming: CGRect, typeSize: Double
    ) -> Bool {
        let top = max(existing.minY, incoming.minY)
        let bottom = min(existing.maxY, incoming.maxY)
        let shared = bottom - top
        guard shared > 0, shared >= min(existing.height, incoming.height) * 0.5 else { return false }
        // Continues to the right of the run, within a few characters' gap.
        let gap = incoming.minX - existing.maxX
        return gap > -existing.width * 0.5 && gap < CGFloat(typeSize) * 6
    }

    /// The two runs joined: the box that holds the appended TEXT, measured — not
    /// merely the union of the two boxes. The union is a lower bound (the joined
    /// words set tighter than two hand-written stretches), and using it alone
    /// clipped every line that grew a word at a time.
    public static func merged(
        existing: CGRect,
        incoming: CGRect,
        text: String,
        typeSize: Double,
        lineSpacing: Double,
        metrics: TextMetrics,
        in pageSize: CGSize
    ) -> CGRect {
        let anchor = CGRect(
            x: existing.minX, y: existing.midY,
            width: max(existing.width, incoming.maxX - existing.minX), height: 0
        )
        var frame = self.frame(
            inkBounds: anchor, text: text, typeSize: typeSize,
            lineSpacing: lineSpacing, metrics: metrics, in: pageSize,
            minimumWidth: Double(existing.width)
        )
        // The run keeps its own top edge: a growing line must not creep upward as
        // it gets taller, or the words wander off the ruling they were written on.
        frame.origin.y = min(existing.minY, Double(pageSize.height) - frame.height - 4)
        return frame
    }
}
