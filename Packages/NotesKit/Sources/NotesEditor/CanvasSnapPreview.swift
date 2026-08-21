import CoreGraphics
import NotesModels
import PencilKit
import UIKit

/// Hold-to-snap, live: the shape settles under a pencil that is still down, and
/// stays adjustable until it lifts.
///
/// Kept beside the canvas rather than inside it because the preview is its own
/// machine — a gesture recognizer that never recognizes, a `CAShapeLayer` under
/// the pencil, and a fitted shape that survives the pencil moving on. The ink
/// itself is only rewritten once, on the lift, from the same fitted path the
/// preview drew, so what you watched settle is what ends up on the page.
extension CanvasPageView.Coordinator {
    // MARK: Live shape snapping

    /// Adds the dwell watcher and the preview layer to a canvas.
    func attachDwellWatcher(to canvas: PageCanvasView) {
        snapPreviewLayer.fillColor = nil
        snapPreviewLayer.lineCap = .round
        snapPreviewLayer.lineJoin = .round
        snapPreviewLayer.opacity = 0
        canvas.layer.addSublayer(snapPreviewLayer)

        let watcher = StrokeDwellRecognizer(target: nil, action: nil)
        // A real Apple Pencil's very FIRST touch sample at touchdown
        // intermittently reports as `.direct` rather than `.pencil` — the
        // altitude/azimuth data that disambiguates it doesn't always arrive on
        // sample one. `allowedTouchTypes` filters at the moment `touchesBegan`
        // is delivered: restricting it to `[.pencil]` meant that on the (fairly
        // common, hardware-dependent) touchdowns where the first sample was
        // ambiguous, UIKit silently never delivered the touch to this
        // recognizer AT ALL — not even once the later samples correctly
        // resolved to `.pencil` — so `onDwell`/`onProgress` never fired for
        // that stroke and every live preview (hold-to-snap, live ruling) fell
        // straight through to its release-time fallback, which is exactly the
        // "only ever seems to work after lift" symptom this kept shipping
        // with despite every fix to the recognizer's OWN state machine.
        // `PageCanvasView.hitTest` already keeps genuine finger touches from
        // ever reaching a `.pencilOnly` canvas in the first place (see its own
        // explicit `touch.type == .direct` check), so allowing both types
        // here doesn't risk tracking a real finger — it only stops this
        // recognizer's OWN, stricter filter from re-rejecting the pencil a
        // second time on a misreported first sample.
        watcher.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        watcher.logicalPoint = { [weak canvas] touch in
            guard let canvas, canvas.zoomScale > 0 else { return .zero }
            // A scroll view hands back content coordinates already; the zoom
            // is what stands between those and the page's own space.
            let point = touch.location(in: canvas)
            return CGPoint(x: point.x / canvas.zoomScale, y: point.y / canvas.zoomScale)
        }
        // Keeps the hold-still tolerance a constant SCREEN distance regardless
        // of how small the page is currently shown — see the doc on
        // `holdRadius` for why a fixed logical radius isn't enough.
        watcher.zoomScale = { [weak canvas] in canvas?.zoomScale ?? 1 }
        watcher.onDwell = { [weak self] points in self?.previewSnap(points) ?? false }
        watcher.onAdjust = { [weak self] point in self?.adjustSnap(to: point) }
        watcher.onProgress = { [weak self] points in self?.previewRuled(points) ?? false }
        watcher.onResume = { [weak self] in self?.cancelSnapPreview() }
        watcher.onEnd = { [weak self] held in
            guard let self else { return }
            self.hideSnapPreview()
            self.liveSnap = nil
            self.isOnDetent = false
            // `isRulingLive`/`pendingSnapPath`/`strokeCountAtSnap`/`pendingSnapInk`/
            // `pendingSnapWidth` are read later, by `commitPending` — on a 90ms
            // debounce AFTER this returns (`finishHeldStroke` → `scheduleInkPass`).
            // Clearing them here unconditionally raced that later read: `isRulingLive`
            // came back false even for a genuinely ruled line (so it always logged
            // as "Shape" on the undo stack, never "Ruled Line"), and had a real hold
            // NOT reset these it would have thrown the accepted shape away outright.
            // Only the "nothing was actually accepted" path clears them — same as
            // it already did for `pendingSnapPath`/`strokeCountAtSnap`.
            if !held {
                self.isRulingLive = false
                self.pendingSnapPath = nil
                self.strokeCountAtSnap = nil
                self.pendingSnapInk = nil
                self.pendingSnapWidth = nil
            }
            self.finishHeldStroke()
        }
        canvas.addGestureRecognizer(watcher)
        dwellWatcher = watcher
    }

    // MARK: Live ruling

    /// The straight-edge, applied WHILE the line is being drawn.
    ///
    /// Ruling used to happen in the deferred ink pass, i.e. after the pencil had
    /// lifted — so the line you watched yourself draw was crooked, and the
    /// straight one appeared later. A ruler that corrects you afterwards is a
    /// picture of a ruler. This takes the stroke over the moment it is clearly
    /// running along an edge and previews the projected line under the pencil,
    /// exactly like a settled shape; `runInkPass` commits the same path on lift.
    ///
    /// Returns whether the straight-edge has taken the stroke.
    func previewRuled(_ points: [CGPoint]) -> Bool {
        guard let guide = rulerGuide, toolState.tool == .pen,
              let straight = guide.straightened(
                  points, inset: CGFloat(toolState.penSettings.effectiveWidth) / 2
              ) else { return false }
        isRulingLive = true
        pendingSnapPath = straight
        suppressLiveInk()
        drawSnapPreview(straight)
        return true
    }

    /// `toolState.snapTolerance` is a constant SCREEN distance (same convention
    /// as `StrokeDwellRecognizer`'s own rest radius, see `watcher.zoomScale`
    /// above) but `points` here are already in logical/page space — dividing by
    /// the current zoom converts the setting into the same space the fitter
    /// operates in. Left unconverted, the fitter's effective tolerance drifted
    /// with zoom (too tight when zoomed out, too loose when zoomed in), which
    /// was enough on its own to make `ShapeSnapper.liveSnap` miss a fit even
    /// when the recognizer had genuinely detected a hold.
    var logicalSnapTolerance: CGFloat {
        ShapeSnapper.holdRadius(forTolerance: CGFloat(toolState.snapTolerance), zoomScale: canvas?.zoomScale ?? 1)
    }

    /// The pencil has come to rest: fit what's been drawn and show it. Returns
    /// false when the ink isn't a shape yet, so the watcher stays armed for the
    /// pause that comes once it is.
    private func previewSnap(_ points: [CGPoint]) -> Bool {
        // `points` here is the watcher's OWN raw touch samples — real jitter and
        // all — not PencilKit's fitted spline. The release-only fallback
        // (`ShapeSnapper.snapped`) classifies `PKStroke.path.interpolatedPoints`,
        // which is already smoothed by the time it's fitted; classifying this
        // path's tremor directly made `classify`'s straightness/corner/residual
        // thresholds miss far more often live than on release, which is why a
        // hold only ever seemed to work once the pencil lifted. Smoothing before
        // classification (endpoints pinned, so the anchor/handle stay exactly
        // where the pencil is) puts the live path on equal footing with the
        // release path's own already-clean geometry.
        let smoothed = StrokeSmoothing.smooth(points, window: 7)
        guard toolState.snapShapes, toolState.tool == .pen,
              // A scrub is an erasure, not a shape. Fitting it to an ellipse
              // under the pencil would beat the eraser to the same ink.
              !(toolState.scribbleToErase && ScribbleDetector.isErasureScribble(points)),
              let snap = ShapeSnapper.liveSnap(smoothed, holdRadius: logicalSnapTolerance),
              let settled = ShapeSnapper.resolve(snap, handle: snap.handle) else { return false }
        liveSnap = snap
        pendingSnapPath = settled.path
        // Take the wandering ink out from under the shape. From here the shape
        // IS the stroke: the pencil sizes it, and the page gets it on the lift.
        suppressLiveInk()
        drawSnapPreview(settled.path)
        isOnDetent = settled.isDetent
        // The shape landing under your pencil should feel like it clicked.
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        return true
    }

    /// The pencil is still down and has moved: it's holding the shape's free
    /// end, so redraw the SAME shape at the new size or angle.
    private func adjustSnap(to point: CGPoint) {
        guard var snap = liveSnap,
              let settled = ShapeSnapper.resolve(snap, handle: point) else { return }
        snap.handle = point
        liveSnap = snap
        pendingSnapPath = settled.path
        drawSnapPreview(settled.path)

        // A line that has just clicked onto level or upright — or a box that has
        // just clicked square — taps the hand, so a perfect edge is something you
        // can feel for rather than squint at. Only on the way IN: a detent that
        // buzzes for every sample it stays inside is a rattle, not a cue.
        if settled.isDetent, !isOnDetent {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        isOnDetent = settled.isDetent
    }

    private func drawSnapPreview(_ path: [CGPoint]) {
        guard let canvas else { return }
        // Back on top. PencilKit adds and re-orders its own layers as it draws,
        // and a preview that ends up underneath them is a shape the user is told
        // has settled but cannot see.
        if canvas.layer.sublayers?.last !== snapPreviewLayer {
            canvas.layer.addSublayer(snapPreviewLayer)
        }
        let scale = canvas.zoomScale
        let bezier = UIBezierPath()
        for (index, point) in path.enumerated() {
            let scaled = CGPoint(x: point.x * scale, y: point.y * scale)
            if index == 0 { bezier.move(to: scaled) } else { bezier.addLine(to: scaled) }
        }
        // The preview redraws on every pencil sample while a shape is being
        // adjusted; implicit layer animation would smear it a frame behind the
        // pencil, which reads as lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapPreviewLayer.path = bezier.cgPath
        snapPreviewLayer.lineWidth = max(1, toolState.penSettings.effectiveWidth * scale)
        snapPreviewLayer.strokeColor = (canvas.tool as? PKInkingTool)?.color.cgColor
        snapPreviewLayer.opacity = 1
        CATransaction.commit()
    }

    private func cancelSnapPreview() {
        pendingSnapPath = nil
        liveSnap = nil
        isOnDetent = false
        hideSnapPreview()
    }

    private func hideSnapPreview() {
        snapPreviewLayer.opacity = 0
        snapPreviewLayer.path = nil
    }
}
