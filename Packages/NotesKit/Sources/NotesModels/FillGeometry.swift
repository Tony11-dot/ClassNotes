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

    // MARK: - Erasing a fill

    /// Rasterizes `outline`'s interior, subtracts a `radius`-sized disc at every
    /// point of `erasedPoints`, and traces the outline of the LARGEST connected
    /// region that survives — nil if nothing does. All points are in the SAME
    /// space `outline` is (page space, typically), with `scale` the raster's
    /// working resolution (pixels per point, same convention as `path(forOutline:
    /// maskOrigin:scale:)`).
    ///
    /// A fill used to be all-or-nothing to the eraser: any contact deleted the
    /// whole element, because the only geometry it had was a hit-test polygon,
    /// not erasable area. Reusing the SAME raster→trace pipeline the paint
    /// bucket itself is built on (rasterize, flood/trace, simplify) means the
    /// eraser can take a real bite out of a fill instead of taking the whole
    /// thing or missing it entirely — a stroke through the middle keeps only the
    /// larger remaining piece rather than splitting into two elements, which
    /// keeps this a bounded, testable extension of geometry that already exists
    /// rather than a new polygon-clipping engine.
    public static func erased(
        outline: [CGPoint], erasedPoints: [CGPoint], radius: CGFloat, scale: CGFloat
    ) -> [CGPoint]? {
        guard outline.count > 2, scale > 0, !erasedPoints.isEmpty else { return outline }
        let minX = outline.map(\.x).min() ?? 0, maxX = outline.map(\.x).max() ?? 0
        let minY = outline.map(\.y).min() ?? 0, maxY = outline.map(\.y).max() ?? 0
        let origin = CGPoint(x: minX, y: minY)
        let width = Int(((maxX - minX) * scale).rounded(.up)) + 1
        let height = Int(((maxY - minY) * scale).rounded(.up)) + 1
        guard width > 1, height > 1 else { return nil }

        var mask = polygonMask(outline, origin: origin, scale: scale, width: width, height: height)
        let radiusPixels = max(1, radius * scale)
        for point in erasedPoints {
            punchHole(
                in: &mask,
                center: (x: (point.x - origin.x) * scale, y: (point.y - origin.y) * scale),
                radius: radiusPixels
            )
        }

        guard let survivor = largestComponent(in: mask) else { return nil }
        let traced = Self.outline(of: survivor)
        guard traced.count > 8 else { return nil }
        let result = Self.path(forOutline: traced, maskOrigin: origin, scale: scale)
        return result.count > 2 ? result : nil
    }

    /// A polygon's interior as a raster, via the same "draw it and read the
    /// pixels" approach `FillTool.inkMask` rasterizes ink with — a scanline
    /// polygon-fill algorithm would be a second implementation of exactly what
    /// `CGContext` already does correctly for self-intersecting/concave outlines.
    private static func polygonMask(
        _ outline: [CGPoint], origin: CGPoint, scale: CGFloat, width: Int, height: Int
    ) -> Mask {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let space = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return Mask(width: width, height: height) }
        context.setFillColor(gray: 1, alpha: 1)
        context.beginPath()
        context.move(to: CGPoint(x: (outline[0].x - origin.x) * scale, y: (outline[0].y - origin.y) * scale))
        for point in outline.dropFirst() {
            context.addLine(to: CGPoint(x: (point.x - origin.x) * scale, y: (point.y - origin.y) * scale))
        }
        context.closePath()
        context.fillPath()
        return Mask(width: width, height: height, pixels: pixels.map { $0 > 127 })
    }

    private static func punchHole(in mask: inout Mask, center: (x: CGFloat, y: CGFloat), radius: CGFloat) {
        let minX = max(0, Int((center.x - radius).rounded(.down)))
        let maxX = min(mask.width - 1, Int((center.x + radius).rounded(.up)))
        let minY = max(0, Int((center.y - radius).rounded(.down)))
        let maxY = min(mask.height - 1, Int((center.y + radius).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        let radiusSquared = radius * radius
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = CGFloat(x) - center.x, dy = CGFloat(y) - center.y
                if dx * dx + dy * dy <= radiusSquared { mask[x, y] = false }
            }
        }
    }

    /// The largest connected component of `true` pixels, as its own mask — or
    /// nil if there are none. Scanline flood fill, same shape as `region(in:
    /// from:)` but finding INK-like (`true`) components instead of flooding the
    /// space around them.
    private static func largestComponent(in mask: Mask) -> Mask? {
        var visited = Mask(width: mask.width, height: mask.height)
        var best: (mask: Mask, count: Int)?

        for startY in 0..<mask.height {
            for startX in 0..<mask.width {
                guard mask[startX, startY], !visited[startX, startY] else { continue }
                var component = Mask(width: mask.width, height: mask.height)
                var stack: [(x: Int, y: Int)] = [(startX, startY)]
                var count = 0
                while let seed = stack.popLast() {
                    var left = seed.x
                    var right = seed.x
                    let y = seed.y
                    guard !visited[left, y], mask[left, y] else { continue }
                    while left - 1 >= 0, mask[left - 1, y], !visited[left - 1, y] { left -= 1 }
                    while right + 1 < mask.width, mask[right + 1, y], !visited[right + 1, y] { right += 1 }
                    for x in left...right {
                        visited[x, y] = true
                        component[x, y] = true
                        count += 1
                    }
                    for neighbour in [y - 1, y + 1] where neighbour >= 0 && neighbour < mask.height {
                        var x = left
                        while x <= right {
                            if mask[x, neighbour], !visited[x, neighbour] {
                                stack.append((x, neighbour))
                                while x <= right, mask[x, neighbour] { x += 1 }
                            }
                            x += 1
                        }
                    }
                }
                if count > 0, count > (best?.count ?? 0) { best = (component, count) }
            }
        }
        return best?.mask
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
