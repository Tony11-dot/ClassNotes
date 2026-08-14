import CoreGraphics
import Foundation

/// Filling a closed region of a drawing with colour, as pure geometry.
///
/// The page's ink is vector, but "which region did they tap inside?" is not a
/// vector question — hand-drawn outlines overlap, double back and don't close
/// cleanly, so there is no polygon to look up. It is a raster question: mark
/// every pixel the ink covers, flood out from the tap until you hit ink, then
/// trace the boundary of what you reached and turn THAT back into a polygon.
///
/// Everything here works on a plain boolean mask so it can be tested without a
/// canvas, a renderer or a page. The editor's only job is to produce the mask.
public enum FillGeometry {
    /// A boolean raster: `true` where the ink is.
    public struct Mask: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public var pixels: [Bool]

        public init(width: Int, height: Int, pixels: [Bool]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        public init(width: Int, height: Int, repeating value: Bool = false) {
            self.init(
                width: width, height: height,
                pixels: [Bool](repeating: value, count: max(0, width * height))
            )
        }

        public func contains(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height
        }

        public subscript(x: Int, y: Int) -> Bool {
            get { contains(x, y) ? pixels[y * width + x] : false }
            set { if contains(x, y) { pixels[y * width + x] = newValue } }
        }
    }

    /// How far a fill may spread before it is refused, as a fraction of the page.
    ///
    /// The default is 1: a fill goes wherever the paint can reach. It used to stop
    /// at 92% on the theory that a shape with a gap in it had leaked and filling
    /// the page would bury the notes — but "I meant that one" and "the outline
    /// wasn't quite closed" look identical from here, and refusing meant the
    /// bucket did nothing at all on any shape drawn slightly open. The colour goes
    /// UNDER the ink now (`PageFillLayer`), so a page-wide fill is a background
    /// wash and the writing stays exactly as legible as it was.
    public static let maximumCoverage = 1.0

    /// The region reachable from `origin` without crossing ink.
    ///
    /// Scanline flood fill (runs, not per-pixel recursion) so a full page is a
    /// few thousand spans rather than a few hundred thousand stack frames.
    /// Returns nil when the tap landed ON the ink, or when the fill spread past
    /// `coverageLimit` of the page.
    public static func region(
        in ink: Mask, from origin: (x: Int, y: Int), coverageLimit: Double = maximumCoverage
    ) -> Mask? {
        guard ink.contains(origin.x, origin.y), !ink[origin.x, origin.y] else { return nil }
        var filled = Mask(width: ink.width, height: ink.height)
        var stack: [(x: Int, y: Int)] = [origin]
        var count = 0

        while let seed = stack.popLast() {
            var left = seed.x
            var right = seed.x
            let y = seed.y
            guard !filled[left, y], !ink[left, y] else { continue }

            while left - 1 >= 0, !ink[left - 1, y], !filled[left - 1, y] { left -= 1 }
            while right + 1 < ink.width, !ink[right + 1, y], !filled[right + 1, y] { right += 1 }

            for x in left...right {
                filled[x, y] = true
                count += 1
            }
            // Seed the rows above and below, once per contiguous run in each.
            for neighbour in [y - 1, y + 1] where neighbour >= 0 && neighbour < ink.height {
                var x = left
                while x <= right {
                    if !ink[x, neighbour], !filled[x, neighbour] {
                        stack.append((x, neighbour))
                        while x <= right, !ink[x, neighbour] { x += 1 }
                    }
                    x += 1
                }
            }
        }

        let area = Double(ink.width * ink.height)
        guard area > 0, Double(count) / area <= coverageLimit else { return nil }
        guard count > 0 else { return nil }
        return filled
    }

    /// The nearest free pixel to `origin`, searched outward in rings.
    ///
    /// Tapping the bucket exactly on a line is a miss by a pixel or two, not a
    /// change of mind — the fill belongs in the region beside the stroke, which is
    /// what the tap was aiming at. Returns nil when the tap is buried in ink.
    public static func freePixel(
        near origin: (x: Int, y: Int), in ink: Mask, radius: Int = 12
    ) -> (x: Int, y: Int)? {
        if ink.contains(origin.x, origin.y), !ink[origin.x, origin.y] { return origin }
        guard radius > 0 else { return nil }
        for ring in 1...radius {
            for dy in -ring...ring {
                for dx in -ring...ring where abs(dx) == ring || abs(dy) == ring {
                    let candidate = (x: origin.x + dx, y: origin.y + dy)
                    if ink.contains(candidate.x, candidate.y), !ink[candidate.x, candidate.y] {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    /// The outline of a filled region, traced clockwise from its top-left pixel.
    ///
    /// Moore-neighbour tracing: walk the boundary keeping the region on one side.
    /// The result is a closed ring in mask coordinates, one point per boundary
    /// pixel — `simplified(_:tolerance:)` is what makes it a usable path.
    public static func outline(of region: Mask) -> [CGPoint] {
        guard let start = firstPixel(of: region) else { return [] }
        // Clockwise from due west, so the first probe is outside the region.
        let neighbours = [
            (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)
        ]
        var contour: [CGPoint] = [CGPoint(x: start.x, y: start.y)]
        var current = start
        var backtrack = 0
        let limit = region.width * region.height * 4

        for _ in 0..<limit {
            var found = false
            for step in 1...8 {
                let index = (backtrack + step) % 8
                let candidate = (
                    x: current.x + neighbours[index].0,
                    y: current.y + neighbours[index].1
                )
                if region[candidate.x, candidate.y] {
                    // Come back in facing where we came from.
                    backtrack = (index + 5) % 8
                    current = candidate
                    contour.append(CGPoint(x: candidate.x, y: candidate.y))
                    found = true
                    break
                }
            }
            guard found else { break }
            if current == start, contour.count > 2 { break }
        }
        return contour
    }

    private static func firstPixel(of region: Mask) -> (x: Int, y: Int)? {
        for y in 0..<region.height {
            for x in 0..<region.width where region[x, y] {
                return (x, y)
            }
        }
        return nil
    }

    /// Ramer–Douglas–Peucker: drops the points that were only ever describing a
    /// straight run. A traced outline has one point per boundary pixel — tens of
    /// thousands for a page-sized region — and every one of them would be written
    /// into the manifest and re-drawn on every frame.
    public static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var ranges = [(0, points.count - 1)]

        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            var worst: CGFloat = 0
            var index = first
            for candidate in (first + 1)..<last {
                let distance = perpendicular(points[candidate], points[first], points[last])
                if distance > worst {
                    worst = distance
                    index = candidate
                }
            }
            guard worst > tolerance else { continue }
            keep[index] = true
            ranges.append((first, index))
            ranges.append((index, last))
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func perpendicular(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
    }

    /// A traced outline as a page-space polygon.
    ///
    /// The ring is grown by half a pixel before being scaled back, so the colour
    /// tucks UNDER the stroke that bounds it. Without that, the fill stops at the
    /// outer edge of the ink's antialiasing and leaves a pale halo following every
    /// line — which reads as a fill that missed.
    public static func path(
        forOutline outline: [CGPoint],
        maskOrigin: CGPoint,
        scale: CGFloat,
        tolerance: CGFloat = 1.1
    ) -> [CGPoint] {
        let simplified = simplified(outline, tolerance: tolerance)
        guard simplified.count > 2, scale > 0 else { return [] }
        let centre = centroid(simplified)
        let growth: CGFloat = 1.2
        return simplified.map { point in
            let outward = CGVector(dx: point.x - centre.x, dy: point.y - centre.y)
            let length = hypot(outward.dx, outward.dy)
            let grown = length > 0.0001
                ? CGPoint(
                    x: point.x + outward.dx / length * growth,
                    y: point.y + outward.dy / length * growth
                )
                : point
            return CGPoint(
                x: maskOrigin.x + grown.x / scale,
                y: maskOrigin.y + grown.y / scale
            )
        }
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for point in points {
            x += point.x
            y += point.y
        }
        return CGPoint(x: x / CGFloat(points.count), y: y / CGFloat(points.count))
    }
}
