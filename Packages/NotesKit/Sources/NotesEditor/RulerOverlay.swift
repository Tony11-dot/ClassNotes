import ClassMateTheme
import SwiftUI

/// A translucent straight-edge you position with two draggable ends — one per
/// hand — while drawing a line against it with the Pencil. Each endpoint is its
/// own handle, so two fingers adjust each side independently (rotation + length
/// fall out of moving the two ends). Honors Reduce Transparency via the theme
/// glass helper.
struct RulerOverlay: View {
    @Environment(\.theme) private var theme

    @Binding var isVisible: Bool
    @State private var start: CGPoint?
    @State private var end: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let a = start ?? CGPoint(x: geo.size.width * 0.25, y: geo.size.height * 0.5)
            let b = end ?? CGPoint(x: geo.size.width * 0.75, y: geo.size.height * 0.5)
            ZStack {
                rulerBody(from: a, to: b)
                handle(at: a) { start = clamp($0, in: geo.size) }
                handle(at: b) { end = clamp($0, in: geo.size) }
                closeButton(near: midpoint(a, b))
            }
            .onAppear {
                if start == nil { start = a }
                if end == nil { end = b }
            }
        }
        .allowsHitTesting(isVisible)
        .opacity(isVisible ? 1 : 0)
    }

    private func rulerBody(from a: CGPoint, to b: CGPoint) -> some View {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = max(1, hypot(dx, dy))
        let angle = atan2(dy, dx)
        return ZStack {
            Rectangle()
                .fill(theme.accent.withAlpha(0.14).color)
                .overlay(
                    // Tick marks every ~24pt along the edge.
                    Path { path in
                        var x: CGFloat = 12
                        while x < length - 6 {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: 8))
                            x += 24
                        }
                    }
                    .stroke(theme.accent.color.opacity(0.5), lineWidth: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
                )
                .overlay(
                    Rectangle().stroke(theme.accent.color.opacity(0.7), lineWidth: 1)
                )
                .frame(width: length, height: 44)
                .rotationEffect(.radians(angle))
                .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
    }

    private func handle(at point: CGPoint, onMove: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .fill(theme.accent.color)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 30, height: 30)
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { onMove($0.location) }
            )
            .accessibilityLabel("Ruler handle")
    }

    private func closeButton(near point: CGPoint) -> some View {
        Button {
            isVisible = false
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(theme.ink.color, theme.surfaceRaised.color)
        }
        .position(x: point.x, y: point.y - 40)
        .accessibilityLabel("Hide ruler")
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), size.width),
            y: min(max(0, point.y), size.height)
        )
    }
}
