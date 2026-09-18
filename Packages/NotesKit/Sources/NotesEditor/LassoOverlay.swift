import ClassMateTheme
import NotesDesignSystem
import NotesModels
import PencilKit
import SwiftUI

/// What one lasso caught: the ink strokes and the page elements inside the loop.
struct LassoCatch: Equatable {
    var strokeIndices: [Int] = []
    var elementIDs: [UUID] = []
    /// The loop that caught them, in page-logical points.
    var loop: [CGPoint] = []
    /// The bounding box of everything caught, in page-logical points.
    var bounds: CGRect = .null

    var isEmpty: Bool { strokeIndices.isEmpty && elementIDs.isEmpty }
}

/// Circle something to select it: a dashed loop follows the pencil, and what it
/// encloses gets a marching-ants outline and a menu of things to do with it.
///
/// The loop is drawn in the page's own logical space and scaled to the display,
/// so a selection made at one zoom means the same thing at another.
struct LassoOverlay: View {
    @Environment(\.theme) private var theme

    let displaySize: CGSize
    let logicalSize: CGSize
    /// Runs the hit test against the live page and hands back what was caught.
    let resolve: ([CGPoint]) -> LassoCatch
    let onSelected: (LassoCatch) -> Void

    @State private var trail: [CGPoint] = []

    private var scale: CGFloat {
        logicalSize.width > 0 ? displaySize.width / logicalSize.width : 1
    }

    var body: some View {
        Canvas { context, _ in
            guard trail.count > 1 else { return }
            var path = Path()
            path.move(to: trail[0])
            for point in trail.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: .color(theme.accent.color),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 4])
            )
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in trail.append(value.location) }
                .onEnded { _ in finish() }
        )
    }

    private func finish() {
        defer { trail = [] }
        guard scale > 0 else { return }
        let logical = trail.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
        guard let loop = LassoSelection.closed(logical) else { return }
        var caught = resolve(loop)
        caught.loop = loop
        guard !caught.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSelected(caught)
    }
}

/// The marching-ants outline around a live selection, plus what you can do to it.
///
/// The dashes crawl — a still dashed box reads as a decoration, a crawling one
/// reads as "this is held, and it is waiting for you".
struct LassoSelectionView: View {
    @Environment(\.theme) private var theme

    let selection: LassoCatch
    let displaySize: CGSize
    let logicalSize: CGSize
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    let onMove: (CGSize) -> Void
    /// Live corner-resize: the whole catch (ink AND elements) scales to fit the
    /// new bounds, the same way `onMove` translates the whole catch rather than
    /// just redrawing the marching-ants box around it. Bounds are in the page's
    /// logical space, top-left anchored to match the single-handle pattern
    /// `PageElementsLayer`'s own resize handle already uses.
    let onResize: (CGRect) -> Void
    let onDismiss: () -> Void

    @State private var phase: CGFloat = 0
    @State private var drag: CGSize = .zero
    /// Live resize translation from the corner handle, in DISPLAY points —
    /// same idea as `drag`, so the box grows/shrinks under the finger instead
    /// of only snapping to its new size on release.
    @State private var resizeDelta: CGSize = .zero

    private static let minimumSide: CGFloat = 32

    private var scale: CGFloat {
        logicalSize.width > 0 ? displaySize.width / logicalSize.width : 1
    }

    private var frame: CGRect {
        CGRect(
            x: selection.bounds.minX * scale, y: selection.bounds.minY * scale,
            width: selection.bounds.width * scale, height: selection.bounds.height * scale
        )
    }

    private var liveWidth: CGFloat { max(Self.minimumSide, frame.width + resizeDelta.width) }
    private var liveHeight: CGFloat { max(Self.minimumSide, frame.height + resizeDelta.height) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tapping off the selection puts it down.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    theme.accent.color,
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5], dashPhase: phase)
                )
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.accent.withAlpha(0.08).color)
                )
                .frame(width: liveWidth, height: liveHeight)
                .offset(x: frame.minX + drag.width, y: frame.minY + drag.height)
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            // `drag` is left exactly where the finger left it —
                            // NOT zeroed here — so the box stays put visually
                            // until `selection.bounds` itself catches up (see
                            // `onChange` below). Zeroing it immediately used to
                            // snap the box back to its PRE-drag position for a
                            // frame while `onMove`'s model update was still in
                            // flight, then jump it forward again once that
                            // landed — the resize handle's "shrink then jump"
                            // glitch, which this shares the same cause with.
                            guard scale > 0, value.translation != .zero else {
                                // Nothing to wait for — no `onChange` is coming.
                                drag = .zero
                                return
                            }
                            onMove(CGSize(
                                width: value.translation.width / scale,
                                height: value.translation.height / scale
                            ))
                        }
                )

            resizeHandle
                .offset(
                    x: frame.minX + drag.width + liveWidth - 16,
                    y: frame.minY + drag.height + liveHeight - 16
                )

            actions
                .offset(
                    x: max(8, min(frame.minX + drag.width, displaySize.width - 232)),
                    y: max(8, frame.minY + drag.height - 52)
                )
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .onAppear {
            withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                phase = -24
            }
        }
        // Fires the instant the awaited move/resize actually lands and
        // `selection.bounds` moves to match — the right moment to drop the
        // local drag preview, since `frame` (now built from the NEW bounds)
        // plus the still-live `drag`/`resizeDelta` already reads as the exact
        // same on-screen box the finger left, so clearing them here changes
        // nothing the user can see.
        .onChange(of: selection.bounds) { _, _ in
            drag = .zero
            resizeDelta = .zero
        }
    }

    /// A small, precise grab point at the selection's bottom-right corner,
    /// matching `PageElementsLayer.resizeHandle` — the same gesture the user
    /// already knows from resizing a photo.
    private var resizeHandle: some View {
        Circle()
            .fill(theme.accent.color)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in resizeDelta = value.translation }
                    .onEnded { value in
                        // Same reasoning as the move handle above: `resizeDelta`
                        // stays at its final dragged value until `onChange(of:
                        // selection.bounds)` below zeroes it, once the resize
                        // has actually landed — not before.
                        guard scale > 0 else { return }
                        let width = max(Self.minimumSide, frame.width + value.translation.width) / scale
                        let height = max(Self.minimumSide, frame.height + value.translation.height) / scale
                        let newBounds = CGRect(
                            x: selection.bounds.minX, y: selection.bounds.minY,
                            width: width, height: height
                        )
                        guard newBounds != selection.bounds else {
                            // Nothing to wait for — no `onChange` is coming.
                            resizeDelta = .zero
                            return
                        }
                        onResize(newBounds)
                    }
            )
    }

    private var actions: some View {
        HStack(spacing: 2) {
            action("Copy", systemImage: "doc.on.doc", onCopy)
            action("Duplicate", systemImage: "plus.square.on.square", onDuplicate)
            action("Delete", systemImage: "trash", onDelete, destructive: true)
            action("Done", systemImage: "checkmark", onDismiss)
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .dsGlass(in: Capsule(), interactive: true)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func action(
        _ title: String, systemImage: String,
        _ perform: @escaping () -> Void, destructive: Bool = false
    ) -> some View {
        Button(action: perform) {
            Image(systemName: systemImage)
                .font(.dsSystem(size: 15, weight: .medium))
                .foregroundStyle(destructive ? Color.red : theme.ink.color)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
