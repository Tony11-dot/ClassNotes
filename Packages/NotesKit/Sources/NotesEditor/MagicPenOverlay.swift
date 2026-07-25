import ClassMateTheme
import SwiftUI

/// The AI "magic pen": drag anywhere — circle, highlight, scribble — and it
/// leaves a flowing river-of-colors trail. On release the freeform path is
/// reported so the editor can crop that exact region (text OR image) and hand
/// it to NOVA as the prompt. Not a fixed rectangle.
struct MagicPenOverlay: View {
    @Environment(\.theme) private var theme

    /// The drawn path points, in overlay/view space.
    let onComplete: ([CGPoint]) -> Void
    let onCancel: () -> Void

    @State private var points: [CGPoint] = []

    private static let rainbow = Gradient(colors: [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red
    ])

    var body: some View {
        ZStack {
            theme.ink.withAlpha(0.04).color

            TimelineView(.animation) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 2.4) / 2.4
                Canvas { context, size in
                    guard points.count > 1 else { return }
                    var path = Path()
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }

                    let shading = GraphicsContext.Shading.linearGradient(
                        Self.rainbow,
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                    // Soft glow underlay, then the crisp flowing stroke.
                    var glow = context
                    glow.addFilter(.blur(radius: 11))
                    glow.stroke(path, with: shading,
                                style: StrokeStyle(lineWidth: 22, lineCap: .round, lineJoin: .round))
                    context.stroke(path, with: shading,
                                   style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                }
                .hueRotation(.degrees(phase * 360))   // the colors flow
            }

            VStack {
                Label("Circle or highlight anything — NOVA reads it", systemImage: "wand.and.stars")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(theme.accent.color, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .padding(.top, 12)
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in points.append(value.location) }
                .onEnded { _ in
                    let drawn = points
                    points = []
                    if drawn.count > 3, spans(drawn) {
                        onComplete(drawn)
                    } else {
                        onCancel()
                    }
                }
        )
        // A single tap (no real drag) cancels the mode.
        .onTapGesture { onCancel() }
    }

    /// True when the scribble actually covers some area (not a stray tap).
    private func spans(_ pts: [CGPoint]) -> Bool {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return false }
        return (maxX - minX) > 20 || (maxY - minY) > 20
    }
}

extension Array where Element == CGPoint {
    /// Bounding rectangle of the points, padded and clamped — the region the
    /// magic pen enclosed, used to crop the page for NOVA.
    func boundingRect(padding: CGFloat = 16, in bounds: CGSize) -> CGRect {
        let xs = map(\.x), ys = map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        let rect = CGRect(x: minX - padding, y: minY - padding,
                          width: (maxX - minX) + padding * 2,
                          height: (maxY - minY) + padding * 2)
        return rect.intersection(CGRect(origin: .zero, size: bounds))
    }
}
