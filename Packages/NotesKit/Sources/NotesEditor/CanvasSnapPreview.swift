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
        watcher.logicalPoint = { [weak canvas] touch in
            guard let canvas, canvas.zoomScale > 0 else { return .zero }
            // A scroll view hands back content coordinates already; the zoom
            // is what stands between those and the page's own space.
            let point = touch.location(in: canvas)
            return CGPoint(x: point.x / canvas.zoomScale, y: point.y / canvas.zoomScale)
        }
        watcher.onDwell = { [weak self] points in self?.previewSnap(points) ?? false }
        watcher.onAdjust = { [weak self] point in self?.adjustSnap(to: point) }
        watcher.onResume = { [weak self] in self?.cancelSnapPreview() }
        watcher.onEnd = { [weak self] held in
            guard let self else { return }
            self.hideSnapPreview()
            self.liveSnap = nil
            self.isOnDetent = false
            if !held { self.pendingSnapPath = nil }
        }
        canvas.addGestureRecognizer(watcher)
        dwellWatcher = watcher
    }

    /// The pencil has come to rest: fit what's been drawn and show it. Returns
    /// false when the ink isn't a shape yet, so the watcher stays armed for the
    /// pause that comes once it is.
    private func previewSnap(_ points: [CGPoint]) -> Bool {
        guard toolState.snapShapes, toolState.tool == .pen,
              // A scrub is an erasure, not a shape. Fitting it to an ellipse
              // under the pencil would beat the eraser to the same ink.
              !(toolState.scribbleToErase && ScribbleDetector.isErasureScribble(points)),
              let snap = ShapeSnapper.liveSnap(points),
              let path = ShapeSnapper.path(for: snap, handle: snap.handle) else { return false }
        liveSnap = snap
        pendingSnapPath = path
        drawSnapPreview(path)
        // The shape landing under your pencil should feel like it clicked.
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        return true
    }

    /// The pencil is still down and has moved: it's holding the shape's free
    /// end, so redraw the SAME shape at the new size or angle.
    private func adjustSnap(to point: CGPoint) {
        guard var snap = liveSnap,
              let path = ShapeSnapper.path(for: snap, handle: point) else { return }
        snap.handle = point
        liveSnap = snap
        pendingSnapPath = path
        drawSnapPreview(path)

        // A line that has just clicked onto level or upright taps the hand, so
        // a perfectly straight edge is something you can feel for rather than
        // squint at. Only on the way IN — a detent that buzzes for every
        // sample it stays inside is a rattle, not a cue.
        if case .line = snap.shape {
            let landed = ShapeSnapper.detented(point, from: snap.anchor).isDetent
            if landed, !isOnDetent {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
            isOnDetent = landed
        }
    }

    private func drawSnapPreview(_ path: [CGPoint]) {
        guard let canvas else { return }
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
