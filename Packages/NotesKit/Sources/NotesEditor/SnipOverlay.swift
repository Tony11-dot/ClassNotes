import ClassMateTheme
import NotesDesignSystem
import SwiftUI

/// The AI snip: drag a RECTANGLE around anything on the page and NOVA looks at
/// it.
///
/// It used to be a freehand scribble, which looked lovely and framed badly —
/// a lasso round a diagram takes in half the paragraph beside it, and the region
/// it hands over is the scribble's bounding box anyway. A rectangle you can see
/// while you drag it is the same gesture with the guesswork removed: what is
/// inside the frame is exactly what gets sent.
struct SnipOverlay: View {
    @Environment(\.theme) private var theme

    /// The chosen rectangle, in overlay/view space.
    let onComplete: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var origin: CGPoint?
    @State private var current: CGPoint?

    /// Anything smaller than this is a tap, not a selection.
    private static let minimumSide: CGFloat = 24

    private var rect: CGRect? {
        guard let origin, let current else { return nil }
        return CGRect(
            x: min(origin.x, current.x), y: min(origin.y, current.y),
            width: abs(current.x - origin.x), height: abs(current.y - origin.y)
        )
    }

    var body: some View {
        ZStack {
            // The page dims everywhere except inside the frame, so the snip reads
            // as a hole cut in the dimming rather than a box drawn on top of it.
            Rectangle()
                .fill(theme.ink.withAlpha(0.28).color)
                .reverseMask {
                    if let rect {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .ignoresSafeArea()

            if let rect {
                // A plain, crisp border — no `.shadow`. A shadow here blooms
                // outward from the shape's own alpha silhouette and isn't
                // clipped by the dim layer's cutout above, so it read as a
                // stray glow sitting ABOVE the selection rather than a clean
                // outline around it.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.accent.color, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                ForEach(corners(of: rect), id: \.self) { point in
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: 9, height: 9)
                        .position(point)
                }
            }

            VStack {
                Label(
                    rect == nil
                        ? "Drag a box around anything — NOVA looks at it"
                        : "Let go to ask NOVA",
                    systemImage: "square.dashed.inset.filled"
                )
                .font(.dsFootnote.weight(.semibold))
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
                .onChanged { value in
                    if origin == nil { origin = value.startLocation }
                    current = value.location
                }
                .onEnded { _ in
                    let drawn = rect
                    origin = nil
                    current = nil
                    if let drawn, drawn.width >= Self.minimumSide, drawn.height >= Self.minimumSide {
                        onComplete(drawn)
                    } else {
                        onCancel()
                    }
                }
        )
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }
}

private extension View {
    /// Punches `mask` out of the receiver.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) { mask().blendMode(.destinationOut) }
                .compositingGroup()
        }
    }
}
