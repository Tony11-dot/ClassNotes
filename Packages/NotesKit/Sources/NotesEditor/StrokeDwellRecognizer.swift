import CoreGraphics
import PencilKit
import UIKit

/// Watches the pencil while it draws and reports when it comes to REST, without
/// ever taking the touch away from PencilKit.
///
/// This exists because a stroke can't tell you about a hold until it's finished:
/// `PKStroke` only arrives once the pencil lifts, so "hold to snap" read from the
/// stroke could only ever snap AFTER the release. Watching the live touch is the
/// only way the shape can settle under the pencil while it's still down, which is
/// the whole feel of the gesture.
///
/// It is deliberately a recognizer that never recognizes: it observes touches,
/// reports, and fails. `cancelsTouchesInView` is off and it always ends in
/// `.failed`, so PencilKit's own drawing recognizer is untouched and the ink is
/// never interrupted.
final class StrokeDwellRecognizer: UIGestureRecognizer {
    /// How far the pencil may drift and still count as resting.
    var holdRadius: CGFloat = ShapeSnapper.holdRadius
    /// How long it must rest before the shape settles. Shorter than the
    /// stroke-timing threshold was: the user is watching it happen now, so the
    /// wait is felt rather than merely measured.
    var minimumHold: TimeInterval = 0.28

    /// The path so far, in the canvas's own logical coordinates.
    private(set) var points: [CGPoint] = []

    /// Fired once per stroke, when the pencil has rested long enough. Carries the
    /// path drawn up to the rest.
    var onDwell: (([CGPoint]) -> Void)?
    /// The pencil moved off again after a dwell — whatever was previewed is stale.
    var onResume: (() -> Void)?
    /// The stroke ended. `true` if it ended while resting (i.e. the dwell stands).
    var onEnd: ((Bool) -> Void)?

    /// Converts a touch to the coordinate space the drawing is stored in.
    var logicalPoint: ((UITouch) -> CGPoint)?

    private var dwellTimer: Timer?
    private var restAnchor: CGPoint?
    private var didDwell = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, let map = logicalPoint else { return }
        points = [map(touch)]
        restAnchor = points[0]
        didDwell = false
        armTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, let map = logicalPoint else { return }
        let point = map(touch)
        points.append(point)

        guard let anchor = restAnchor else { return }
        if hypot(point.x - anchor.x, point.y - anchor.y) > holdRadius {
            // Moving again: restart the clock from here, and drop any preview.
            restAnchor = point
            if didDwell {
                didDwell = false
                onResume?()
            }
            armTimer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish()
    }

    override func reset() {
        super.reset()
        dwellTimer?.invalidate()
        dwellTimer = nil
        restAnchor = nil
    }

    private func finish() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        onEnd?(didDwell)
        didDwell = false
        restAnchor = nil
        // Never claim the touch — PencilKit owns it.
        state = .failed
    }

    private func armTimer() {
        dwellTimer?.invalidate()
        let timer = Timer(timeInterval: minimumHold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didDwell, self.points.count > 2 else { return }
                self.didDwell = true
                self.onDwell?(self.points)
            }
        }
        // Common modes, or the timer stops while the finger is scrolling anything.
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }
}
