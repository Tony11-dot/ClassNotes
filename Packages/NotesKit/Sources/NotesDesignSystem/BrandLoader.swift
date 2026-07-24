import ClassMateTheme
import SwiftUI

/// The looping loading animation, rebuilt natively in the spirit of ClassMate's
/// `CmLoading`: the CN monogram draws itself on — the C arc, then the N strokes —
/// then cross-fades into the real mark asset, then restarts. Tinted to the
/// theme accent. Geometry is traced in a 512×512 space (same as ClassMate) so
/// the strokes sit under the real logo when it fades in.
public struct BrandLoader: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let size: CGFloat
    var tint: Color?

    public init(size: CGFloat = 56, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    // Timeline fractions (mirrors CmLoading): C 0–0.36, N 0.32–0.64,
    // strokes→mark crossfade 0.66–0.78, hold + restart fade 0.90–1.0.
    private static let period: Double = 2.0

    public var body: some View {
        let color = tint ?? theme.accent.color
        if reduceMotion {
            BrandMark(size: size, tint: color)
        } else {
            TimelineView(.animation) { timeline in
                let phase = (timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.period)) / Self.period
                ZStack {
                    Canvas { context, canvasSize in
                        let scale = canvasSize.width / 512
                        var transform = CGAffineTransform(scaleX: scale, y: scale)
                        let cProgress = clampProgress(phase, 0.0, 0.36)
                        let nProgress = clampProgress(phase, 0.32, 0.64)
                        let strokeAlpha = 1 - clampProgress(phase, 0.66, 0.78)

                        context.opacity = strokeAlpha
                        if let cPath = Self.cPath(progress: cProgress)?.applying(transform) {
                            context.stroke(
                                cPath,
                                with: .color(color),
                                style: StrokeStyle(lineWidth: 44 * scale, lineCap: .round)
                            )
                        }
                        if let nPath = Self.nPath(progress: nProgress)?.applying(transform) {
                            context.stroke(
                                nPath,
                                with: .color(color),
                                style: StrokeStyle(lineWidth: 42 * scale, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                    // Real mark fades in as the strokes finish.
                    BrandMark(size: size, tint: color)
                        .opacity(clampProgress(phase, 0.66, 0.80))
                }
                .opacity(1 - clampProgress(phase, 0.92, 1.0))
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Loading")
        }
    }

    private func clampProgress(_ phase: Double, _ start: Double, _ end: Double) -> Double {
        guard phase > start else { return 0 }
        guard phase < end else { return 1 }
        let raw = (phase - start) / (end - start)
        // easeInOutCubic
        return raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
    }

    /// The C arc (center 237,253, radius 144), drawn from `progress` 0→1.
    private static func cPath(progress: Double) -> Path? {
        guard progress > 0 else { return nil }
        var path = Path()
        let center = CGPoint(x: 237, y: 253)
        let radius: CGFloat = 144
        let startAngle = -43.0
        let sweep = -243.0
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(startAngle + sweep * progress),
            clockwise: sweep < 0
        )
        return path
    }

    /// The N monogram: up the left, diagonal down-right, up the right —
    /// revealed segment-by-segment as `progress` grows.
    private static func nPath(progress: Double) -> Path? {
        guard progress > 0 else { return nil }
        let points = [
            CGPoint(x: 210, y: 410),
            CGPoint(x: 210, y: 200),
            CGPoint(x: 400, y: 410),
            CGPoint(x: 400, y: 200)
        ]
        return partialPolyline(points, progress: progress)
    }

    /// Draws a polyline up to `progress` of its total length.
    private static func partialPolyline(_ points: [CGPoint], progress: Double) -> Path? {
        guard points.count > 1 else { return nil }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for index in 1..<points.count {
            let segment = hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
            lengths.append(segment)
            total += segment
        }
        let target = total * progress
        var path = Path()
        path.move(to: points[0])
        var covered: CGFloat = 0
        for index in 1..<points.count {
            let segment = lengths[index - 1]
            if covered + segment <= target {
                path.addLine(to: points[index])
                covered += segment
            } else {
                let remaining = target - covered
                let fraction = segment > 0 ? remaining / segment : 0
                let interpolated = CGPoint(
                    x: points[index - 1].x + (points[index].x - points[index - 1].x) * fraction,
                    y: points[index - 1].y + (points[index].y - points[index - 1].y) * fraction
                )
                path.addLine(to: interpolated)
                break
            }
        }
        return path
    }
}
