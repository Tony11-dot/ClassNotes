import ClassMateTheme
import NotesDesignSystem
import SwiftUI
import UIKit

/// Where the straight-edge is sitting, in the editor's own coordinate space.
/// Published upwards so the ink pass can rule the strokes drawn along it.
struct RulerLine: Equatable {
    var start: CGPoint
    var end: CGPoint
}

/// A translucent straight-edge you position with two draggable ends — one per
/// hand — while drawing a line against it with the Pencil. Each endpoint is its
/// own handle, so two fingers adjust each side independently (rotation + length
/// fall out of moving the two ends). Honors Reduce Transparency via the theme
/// glass helper.
///
/// It is a real straight-edge, not a picture of one: ink drawn along either long
/// edge is projected onto that edge (`RulerGuide`), so the line comes out exactly
/// straight however much the hand wandered up and down it.
struct RulerOverlay: View {
    @Environment(\.theme) private var theme

    @Binding var isVisible: Bool
    /// Reported up so the pages can convert it into their own space.
    @Binding var line: RulerLine?

    @State private var start: CGPoint?
    @State private var end: CGPoint?
    /// Whether each handle's last reported drag point was sitting on a
    /// level/upright detent — edge-triggered so the haptic fires once on
    /// entry rather than rattling for as long as the hand stays near axis.
    @State private var startOnDetent = false
    @State private var endOnDetent = false
    /// Both endpoints as they were when a middle-drag began, so the translation
    /// is relative to that moment rather than accumulating from wherever the
    /// ruler happened to already be.
    @State private var bodyDragBase: (start: CGPoint, end: CGPoint)?

    /// How wide the straight-edge is. Both long edges guide, so this is also how
    /// far apart the two guides are.
    static let thickness: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let a = start ?? CGPoint(x: geo.size.width * 0.25, y: geo.size.height * 0.5)
            let b = end ?? CGPoint(x: geo.size.width * 0.75, y: geo.size.height * 0.5)
            ZStack {
                rulerBody(from: a, to: b, in: geo.size)
                readout(from: a, to: b)
                handle(at: a, anchor: b, wasOnDetent: $startOnDetent) { start = clamp($0, in: geo.size) }
                handle(at: b, anchor: a, wasOnDetent: $endOnDetent) { end = clamp($0, in: geo.size) }
                closeButton(near: midpoint(a, b))
            }
            .onAppear {
                if start == nil { start = a }
                if end == nil { end = b }
                publish(a, b)
            }
            .onChange(of: RulerLine(start: a, end: b)) { _, updated in
                line = isVisible ? updated : nil
            }
            .onChange(of: isVisible) { _, visible in
                line = visible ? RulerLine(start: a, end: b) : nil
            }
        }
        .allowsHitTesting(isVisible)
        .opacity(isVisible ? 1 : 0)
    }

    private func publish(_ a: CGPoint, _ b: CGPoint) {
        line = isVisible ? RulerLine(start: a, end: b) : nil
    }

    /// The straight-edge itself, draggable from the body: moving it this way
    /// translates both ends by the same amount, which by construction can never
    /// change the length or angle — rotation stays exclusively on the two
    /// endpoint handles.
    private func rulerBody(from a: CGPoint, to b: CGPoint, in size: CGSize) -> some View {
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
                .frame(width: length, height: Self.thickness)
                .rotationEffect(.radians(angle))
                .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let base = bodyDragBase ?? (start: a, end: b)
                            if bodyDragBase == nil { bodyDragBase = base }
                            // Clamp the TRANSLATION, not each endpoint separately —
                            // clamping the points independently would let one end
                            // hit the edge before the other and silently change the
                            // angle/length, defeating the whole point of a
                            // pure-translation drag.
                            let minDX = -min(base.start.x, base.end.x)
                            let maxDX = size.width - max(base.start.x, base.end.x)
                            let minDY = -min(base.start.y, base.end.y)
                            let maxDY = size.height - max(base.start.y, base.end.y)
                            let dx = min(max(value.translation.width, minDX), maxDX)
                            let dy = min(max(value.translation.height, minDY), maxDY)
                            start = CGPoint(x: base.start.x + dx, y: base.start.y + dy)
                            end = CGPoint(x: base.end.x + dx, y: base.end.y + dy)
                        }
                        .onEnded { _ in bodyDragBase = nil }
                )
        }
    }

    /// Floating length (cm / in) + angle readout, offset above the ruler's
    /// midpoint. Length uses the print convention (72 pt = 1 in = 2.54 cm) so
    /// the straight-edge reads like a document ruler; angle is from horizontal.
    private func readout(from a: CGPoint, to b: CGPoint) -> some View {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let points = hypot(dx, dy)
        let inches = points / 72.0
        let cm = inches * 2.54
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let mid = midpoint(a, b)
        // Push the label to the side the ruler isn't rotating into.
        let normal = CGVector(dx: -dy, dy: dx)
        let len = max(1, hypot(normal.dx, normal.dy))
        let offset = CGPoint(x: mid.x + normal.dx / len * 40, y: mid.y + normal.dy / len * 40)
        return Text(String(format: "%.1f cm · %.1f in · %.0f°", cm, inches, degrees))
            .font(.dsCaption.weight(.semibold).monospacedDigit())
            .foregroundStyle(theme.ink.color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(theme.surfaceRaised.color, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.color, lineWidth: 0.5))
            .position(offset)
            .allowsHitTesting(false)
    }

    /// A draggable end of the straight-edge. Dragging it rotates the ruler
    /// around the OTHER end (`anchor`); as that angle nears level or upright,
    /// `ShapeSnapper.detented` — the same eased pull-to-axis a held shape
    /// already gets — resists the hand and settles the ruler exactly onto the
    /// axis, with a haptic tap on the way in so it can be felt, not squinted
    /// at.
    private func handle(
        at point: CGPoint, anchor: CGPoint, wasOnDetent: Binding<Bool>,
        onMove: @escaping (CGPoint) -> Void
    ) -> some View {
        Circle()
            .fill(theme.accent.color)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 30, height: 30)
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let settled = ShapeSnapper.detented(value.location, from: anchor)
                        if settled.isDetent, !wasOnDetent.wrappedValue {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        }
                        wasOnDetent.wrappedValue = settled.isDetent
                        onMove(settled.point)
                    }
                    .onEnded { _ in wasOnDetent.wrappedValue = false }
            )
            .accessibilityLabel("Ruler handle")
    }

    private func closeButton(near point: CGPoint) -> some View {
        Button {
            isVisible = false
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.dsSystem(size: 22))
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
