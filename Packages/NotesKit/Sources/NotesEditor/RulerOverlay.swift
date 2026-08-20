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

/// A translucent straight-edge, moved with one finger and turned with two —
/// the same two-hand vocabulary as the real object: one hand to place it, two
/// fingers of the other to turn it, while drawing a line against it with the
/// Pencil.
///
/// It always spans the full width of the editor surface (well past either
/// edge at any angle, then clipped to it) rather than a user-set length
/// between two draggable ends: a straight-edge you reach for to rule a line is
/// a WALL to draw against, not a segment you'd resize first. Dropping the two
/// endpoint handles is what makes room for that — they existed to set length
/// and angle both, and length stopped being a thing to set.
///
/// It is a real straight-edge, not a picture of one: ink drawn along either long
/// edge is projected onto that edge (`RulerGuide`), so the line comes out exactly
/// straight however much the hand wandered up and down it.
struct RulerOverlay: View {
    @Environment(\.theme) private var theme

    @Binding var isVisible: Bool
    /// Reported up so the pages can convert it into their own space.
    @Binding var line: RulerLine?

    @State private var center: CGPoint?
    @State private var angle: CGFloat = 0
    /// Edge-triggered so the haptic fires once on entry rather than rattling
    /// for as long as the hand stays near a right angle.
    @State private var wasOnDetent = false
    @State private var dragBase: CGPoint?
    /// The angle when a two-finger rotation began, so the gesture's own
    /// relative delta (`UIRotationGestureRecognizer.rotation`) adds onto where
    /// the ruler already was rather than replacing it.
    @State private var rotateBase: CGFloat?

    /// How wide the straight-edge is. Both long edges guide, so this is also how
    /// far apart the two guides are.
    static let thickness: CGFloat = 72
    /// One tick per centimetre — the print convention (72pt = 1in = 2.54cm)
    /// this ruler already reads its length in.
    private static let tickSpacing: CGFloat = 72 / 2.54
    /// How close to a right angle counts as "on the detent" — generous enough
    /// to catch a hand settling near level/upright, tight enough that turning
    /// past it doesn't feel sticky.
    private static let detentTolerance: CGFloat = 4 * .pi / 180

    var body: some View {
        GeometryReader { geo in
            let mid = center ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Comfortably longer than the diagonal so the straight-edge reaches
            // past every corner of the surface whatever it's turned to; the
            // outer `.clipped()` keeps it from drawing (or being grabbed)
            // beyond the editor's own bounds.
            let length = hypot(geo.size.width, geo.size.height) * 1.3
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let a = CGPoint(x: mid.x - direction.x * length / 2, y: mid.y - direction.y * length / 2)
            let b = CGPoint(x: mid.x + direction.x * length / 2, y: mid.y + direction.y * length / 2)
            // Perpendicular to the ruler's own direction, so the readout and
            // close button stay clear of its edge — and off to the same
            // relative side — however far it's been turned.
            let perp = CGPoint(x: -direction.y, y: direction.x)
            let above: (CGFloat) -> CGPoint = { distance in
                CGPoint(x: mid.x - perp.x * distance, y: mid.y - perp.y * distance)
            }

            ZStack {
                rulerBody(center: mid, angle: angle, length: length)
                readout(at: above(Self.thickness / 2 + 20))
                closeButton(near: above(Self.thickness / 2 + 54))
            }
            .clipped()
            .onAppear {
                if center == nil { center = mid }
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

    /// How close `value` sits to a multiple of 90°, and the nearest such
    /// multiple — pulls the turn onto level/upright the same way a held shape
    /// clicks onto its own detents, just measured in angle instead of position.
    private func detented(_ value: CGFloat) -> (angle: CGFloat, isDetent: Bool) {
        let step = CGFloat.pi / 2
        let nearest = (value / step).rounded() * step
        return abs(value - nearest) < Self.detentTolerance ? (nearest, true) : (value, false)
    }

    /// The straight-edge itself: one finger drags it (translating `center`,
    /// which can never change the angle by construction), two fingers turn it.
    private func rulerBody(center: CGPoint, angle: CGFloat, length: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(theme.accent.withAlpha(0.14).color)
                .overlay(ticks(length: length), alignment: .center)
                .overlay(Rectangle().stroke(theme.accent.color.opacity(0.7), lineWidth: 1))
                // Decoration only — see `FingerDragArea`'s own doc comment for
                // why a hit-testable sibling here is what used to swallow
                // Pencil strokes drawn hard against the ruler's own paint.
                .allowsHitTesting(false)
                .overlay(
                    FingerDragArea(
                        onChanged: { value in
                            let base = dragBase ?? center
                            if dragBase == nil { dragBase = base }
                            self.center = CGPoint(
                                x: base.x + value.translation.width, y: base.y + value.translation.height
                            )
                        },
                        onEnded: { _ in dragBase = nil }
                    )
                )
                .overlay(
                    FingerRotationArea(
                        onChanged: { rotation in
                            let base = rotateBase ?? angle
                            if rotateBase == nil { rotateBase = base }
                            let settled = detented(base + rotation)
                            if settled.isDetent, !wasOnDetent {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            }
                            wasOnDetent = settled.isDetent
                            self.angle = settled.angle
                        },
                        onEnded: { _ in
                            rotateBase = nil
                            wasOnDetent = false
                        }
                    )
                )
                .frame(width: length, height: Self.thickness)
                .rotationEffect(.radians(angle))
                .position(center)
        }
    }

    /// Tick marks every centimetre along both edges, each labelled with its
    /// own measurement — a scale you can read off, not just hashes that show
    /// where a centimetre falls without saying which one. Alternates the label
    /// above/below so an unrotated ruler's numbers don't collide with the
    /// close button sitting just above it.
    private func ticks(length: CGFloat) -> some View {
        Canvas { context, size in
            let centerX = size.width / 2
            var offset = Self.tickSpacing
            var cm = 1
            while offset < centerX {
                for sign: CGFloat in [1, -1] {
                    let x = centerX + offset * sign
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: 0))
                    tick.addLine(to: CGPoint(x: x, y: 9))
                    var bottomTick = Path()
                    bottomTick.move(to: CGPoint(x: x, y: size.height - 9))
                    bottomTick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(theme.accent.color.opacity(0.5)), lineWidth: 1)
                    context.stroke(bottomTick, with: .color(theme.accent.color.opacity(0.5)), lineWidth: 1)
                    context.draw(
                        Text("\(cm)").font(.dsCaption2).foregroundStyle(theme.accent.color.opacity(0.7)),
                        at: CGPoint(x: x, y: 20)
                    )
                }
                offset += Self.tickSpacing
                cm += 1
            }
            var zero = Path()
            zero.move(to: CGPoint(x: centerX, y: 0))
            zero.addLine(to: CGPoint(x: centerX, y: size.height))
            context.stroke(zero, with: .color(theme.accent.color.opacity(0.7)), lineWidth: 1.4)
        }
    }

    /// Floating angle readout. Length isn't a separately-set thing any more
    /// (the straight-edge always spans the surface), so the angle is the one
    /// number left worth showing.
    private func readout(at point: CGPoint) -> some View {
        var degrees = angle * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return Text(String(format: "%.0f°", degrees))
            .font(.dsCaption.weight(.semibold).monospacedDigit())
            .foregroundStyle(theme.ink.color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(theme.surfaceRaised.color, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.color, lineWidth: 0.5))
            .position(point)
            .allowsHitTesting(false)
    }

    private func closeButton(near point: CGPoint) -> some View {
        Button {
            isVisible = false
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.dsSystem(size: 22))
                .foregroundStyle(theme.ink.color, theme.surfaceRaised.color)
        }
        .position(point)
        .accessibilityLabel("Hide ruler")
    }
}
