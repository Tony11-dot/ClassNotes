import ClassMateTheme
import NotesDesignSystem
import NotesModels
import PencilKit
import SwiftUI

/// Which stroke a lasso is holding, by what it IS rather than where it sits.
///
/// A selection used to hold indices into the page's `PKDrawing`, captured when
/// the loop closed. Anything that changed the drawing's order before the user
/// pressed a button — live beautification typesetting a line, a stroke landing
/// from a page that was still loading, an undo — left those indices pointing at
/// whatever happened to sit there now, and Move or Delete acted on ink nobody
/// circled. `PKStroke` has no id, so the key is built from what does not change
/// while a stroke merely exists: when its path was made, how many points it
/// has, and where it is placed (`transform` — which a move or resize changes,
/// so the selection re-keys after each one). A key that matches nothing is a
/// stroke that's gone; it is skipped, never substituted.
struct StrokeKey: Hashable {
    let created: Date
    let pointCount: Int
    let placement: [CGFloat]

    init(_ stroke: PKStroke) {
        created = stroke.path.creationDate
        pointCount = stroke.path.count
        let t = stroke.transform
        placement = [t.a, t.b, t.c, t.d, t.tx, t.ty]
    }

    /// Where each key's stroke sits in `strokes` right now, ascending. Keys with
    /// no stroke left are dropped; identical keys (a stroke duplicated in place)
    /// claim distinct strokes rather than the same one twice.
    static func indices(of keys: [StrokeKey], in strokes: [PKStroke]) -> [Int] {
        var wanted: [StrokeKey: Int] = [:]
        for key in keys { wanted[key, default: 0] += 1 }
        var found: [Int] = []
        for (index, stroke) in strokes.enumerated() where !wanted.isEmpty {
            let key = StrokeKey(stroke)
            guard let remaining = wanted[key] else { continue }
            found.append(index)
            wanted[key] = remaining > 1 ? remaining - 1 : nil
        }
        return found
    }
}

/// What one lasso caught: the ink strokes and the page elements inside the loop.
struct LassoCatch: Equatable {
    /// The strokes caught, by identity — see `StrokeKey`. Resolve them against
    /// the live drawing with `strokeIndices(in:)` at the moment of acting.
    var strokes: [StrokeKey] = []
    var elementIDs: [UUID] = []
    /// The loop that caught them, in page-logical points.
    var loop: [CGPoint] = []
    /// The bounding box of everything caught, in page-logical points.
    var bounds: CGRect = .null
    /// Counts the edits made to the selection (move, resize, turn, colour), so
    /// the view can drop its live preview the moment one lands, even when the
    /// outline didn't change (a square photo turned a quarter).
    var edits = 0

    var isEmpty: Bool { strokes.isEmpty && elementIDs.isEmpty }

    /// Where the caught strokes are in `drawing` now.
    func strokeIndices(in drawing: PKDrawing) -> [Int] {
        StrokeKey.indices(of: strokes, in: drawing.strokes)
    }
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
    /// A tap, or a loop that caught nothing: whatever was held is put down.
    var onDismiss: () -> Void = {}

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
        // Sits UNDER a live selection, so circling something else simply
        // selects that instead — no need to press Done first — and tapping
        // empty paper puts the selection down.
        .onTapGesture { onDismiss() }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in append(value.location) }
                .onEnded { _ in finish() }
        )
    }

    /// The least a point has to travel to be worth keeping, in display points.
    ///
    /// A drag reports far more samples than the loop needs: a slow, careful
    /// lasso emits hundreds, many of them a fraction of a point apart, and
    /// every one of them is both a segment the Canvas redraws each frame and
    /// an edge that `LassoSelection.catches` tests against EVERY sampled point
    /// of EVERY stroke on the page. Two points is below what a hand can aim
    /// anyway, so dropping anything closer costs no accuracy the user could
    /// have exercised and takes a large constant factor off the hit test.
    private static let minimumStep: CGFloat = 2

    private func append(_ point: CGPoint) {
        guard let last = trail.last else {
            trail.append(point)
            return
        }
        let dx = point.x - last.x, dy = point.y - last.y
        guard dx * dx + dy * dy >= Self.minimumStep * Self.minimumStep else { return }
        trail.append(point)
    }

    private func finish() {
        defer { trail = [] }
        guard scale > 0 else { return }
        let logical = trail.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
        guard let loop = LassoSelection.closed(logical) else { return }
        var caught = resolve(loop)
        caught.loop = loop
        guard !caught.isEmpty else {
            onDismiss()
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSelected(caught)
    }
}

/// The marching-ants outline around a live selection, plus what you can do to it.
///
/// The dashes crawl — a still dashed box reads as a decoration, a crawling one
/// reads as "this is held, and it is waiting for you".
struct LassoSelectionView: View {
    @Environment(\.theme) var theme

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
    /// Turns the whole catch about its centre, in radians (clockwise on
    /// screen), once the turn handle is let go.
    let onRotate: (CGFloat) -> Void
    /// Paints the catch in a colour (hex).
    let onRecolor: (String) -> Void
    /// The colours offered for recolouring: the pen palette.
    var palette: [String] = []
    let onDismiss: () -> Void
    /// A picture of what the selection holds, rendered once when a drag starts,
    /// so the content travels under the finger instead of an empty box moving
    /// and the ink jumping after it on release.
    var makePreview: () -> UIImage? = { nil }

    @State private var phase: CGFloat = 0
    @State private var preview: UIImage?
    @State private var previewRequested = false
    @State private var drag: CGSize = .zero
    /// Live resize translation from the corner handle, in DISPLAY points —
    /// same idea as `drag`, so the box grows/shrinks under the finger instead
    /// of only snapping to its new size on release.
    @State private var resizeDelta: CGSize = .zero
    /// The live turn from the rotate handle, in radians — same idea again: the
    /// preview turns under the finger and the ink follows on release.
    @State var turn: CGFloat = 0
    /// Whether the turn is resting on a 15° step, so the haptic fires once on
    /// the way in.
    @State var turnSettled = false
    @State var showColors = false

    private static let minimumSide: CGFloat = 32
    /// How far below the outline the turn handle sits, centre to edge.
    private static let handleDrop: CGFloat = 30
    static let space = "lassoSelection"
    /// Five 44-point buttons plus the capsule's 6-point padding either side.
    /// Derived rather than guessed, so adding another action cannot quietly
    /// start pushing the bar off the right edge.
    private static let actionCount = 5
    private static let actionsWidth = CGFloat(actionCount) * 44 + 12
    private static let actionsHeight: CGFloat = 40

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

    private var actionsOrigin: CGPoint {
        // The turn handle hangs below the outline, so a bar that has to go
        // below goes below the handle too.
        SelectionBarPlacement.origin(
            for: CGRect(
                x: frame.minX + drag.width, y: frame.minY + drag.height,
                width: liveWidth, height: liveHeight + Self.handleDrop + 22
            ),
            barSize: CGSize(width: Self.actionsWidth, height: Self.actionsHeight),
            in: displaySize
        )
    }

    /// The centre the selection turns about, in display points.
    var liveCentre: CGPoint {
        CGPoint(x: frame.minX + drag.width + liveWidth / 2, y: frame.minY + drag.height + liveHeight / 2)
    }

    /// Where the turn handle sits: below the middle of the outline, carried
    /// round with the turn, and never off the page.
    private var handleCentre: CGPoint {
        let rest = CGPoint(x: liveCentre.x, y: liveCentre.y + liveHeight / 2 + Self.handleDrop)
        let turned = rest.applying(SelectionRotation.transform(turn, about: liveCentre))
        return CGPoint(
            x: min(max(turned.x, 22), displaySize.width - 22),
            y: min(max(turned.y, 22), displaySize.height - 22)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tapping off the selection is handled by the lasso surface beneath,
            // which also lets a new loop replace this one directly.
            if isAdjusting, let preview {
                Image(uiImage: preview)
                    .resizable()
                    .frame(width: liveWidth, height: liveHeight)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    .rotationEffect(.radians(turn))
                    .offset(x: frame.minX + drag.width, y: frame.minY + drag.height)
                    .allowsHitTesting(false)
            }

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
                .rotationEffect(.radians(turn))
                .offset(x: frame.minX + drag.width, y: frame.minY + drag.height)
                .gesture(
                    DragGesture()
                        .onChanged {
                            requestPreview()
                            drag = $0.translation
                        }
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

            if turn == 0 {
                resizeHandle
                    .offset(
                        x: frame.minX + drag.width + liveWidth - 22,
                        y: frame.minY + drag.height + liveHeight - 22
                    )
            }

            rotateHandle
                .offset(x: handleCentre.x - 22, y: handleCentre.y - 22)

            if turn == 0 {
                actions
                    .offset(x: actionsOrigin.x, y: actionsOrigin.y)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .coordinateSpace(.named(Self.space))
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
        .onChange(of: selection.bounds) { _, _ in settle() }
        // An edit can land without the outline moving (a square photo turned a
        // quarter); the edit count changes either way.
        .onChange(of: selection.edits) { _, _ in settle() }
    }

    func settle() {
        drag = .zero
        resizeDelta = .zero
        turn = 0
        turnSettled = false
        preview = nil
        previewRequested = false
    }

    private var isAdjusting: Bool { drag != .zero || resizeDelta != .zero || turn != 0 }

    func requestPreview() {
        guard !previewRequested else { return }
        previewRequested = true
        preview = makePreview()
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
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        requestPreview()
                        resizeDelta = value.translation
                    }
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

    /// The bar's buttons, each also reachable from a keyboard.
    ///
    /// An iPad with a keyboard attached is the machine this app is mostly used
    /// on, and ⌘C / ⌘D are what anyone would try first on something they have
    /// just selected. The shortcuts hang off these buttons rather than the
    /// editor, so they exist only while a selection does — there is no hidden
    /// global ⌘C quietly doing something else to the page. Delete takes ⌘⌫
    /// rather than a bare Backspace on purpose: a bare one would fire from
    /// ordinary typing the moment anything else on screen took focus.
    private var actions: some View {
        HStack(spacing: 2) {
            action("Colour", systemImage: "paintpalette", { showColors = true })
                .popover(isPresented: $showColors) { colorPicker }
            action("Copy", systemImage: "doc.on.doc", onCopy)
                .keyboardShortcut("c", modifiers: .command)
            action("Duplicate", systemImage: "plus.square.on.square", onDuplicate)
                .keyboardShortcut("d", modifiers: .command)
            action("Delete", systemImage: "trash", onDelete, destructive: true)
                .keyboardShortcut(.delete, modifiers: .command)
            action("Done", systemImage: "checkmark", onDismiss)
                .keyboardShortcut(.escape, modifiers: [])
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

/// Where a floating action bar goes relative to the thing it acts on.
///
/// Pulled out of the view because this is the whole of the behaviour worth
/// pinning, and a render test cannot see it: the bar is drawn on `dsGlass`, and
/// `ImageRenderer` rasterizes a material as nothing at all, so a pixel read of
/// the rendered view finds an empty page whether the bar is placed correctly,
/// placed off-screen, or placed straight on top of the selection.
enum SelectionBarPlacement {
    /// How close the bar may come to the edge of the page.
    static let margin: CGFloat = 8
    /// The gap between the bar and the selection it belongs to.
    static let gap: CGFloat = 12

    /// Above the selection by preference, below it when there is no room, and
    /// never past an edge.
    ///
    /// The "below" case is the one that matters: clamping to the top margin
    /// instead — which is what a plain `max(margin, …)` does — lays the bar over
    /// the top of the selection, so the buttons cover the very thing they are
    /// about to act on.
    static func origin(for selection: CGRect, barSize: CGSize, in display: CGSize) -> CGPoint {
        let x = max(margin, min(selection.minX, display.width - barSize.width - margin))

        let above = selection.minY - barSize.height - gap
        if above >= margin {
            return CGPoint(x: x, y: above)
        }
        let below = selection.maxY + gap
        let lowest = display.height - barSize.height - margin
        return CGPoint(x: x, y: below <= lowest ? below : max(margin, lowest))
    }
}
