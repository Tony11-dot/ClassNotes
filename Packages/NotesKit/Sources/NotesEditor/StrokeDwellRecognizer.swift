import CoreGraphics
import QuartzCore
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

    /// Whether the pencil is still on the glass. The ink pass reads this: a shape
    /// held under a live pencil is still being sized, so committing it — or
    /// closing a history step around it — has to wait for the lift.
    private(set) var isTouching = false

    /// Fired when the pencil has rested long enough, with the path drawn up to the
    /// rest. Returns whether the rest was USED — a pause over ink that isn't a
    /// shape yet (halfway round a circle) must leave the stroke exactly as it was,
    /// and leave the watcher armed for the pause that comes after the shape is
    /// finished.
    var onDwell: (([CGPoint]) -> Bool)?
    /// The pencil moved after the shape settled. It is now HOLDING the shape's free
    /// end: every report is a new size / direction, not a cancellation.
    ///
    /// This is the difference between a snap you accept and a snap you can work
    /// with. Treating the next movement as "never mind" meant the only way to
    /// change a snapped circle was to undo it and draw another one.
    var onAdjust: ((CGPoint) -> Void)?
    /// The pencil moved off again before anything settled — drop any preview.
    var onResume: (() -> Void)?
    /// The stroke ended. `true` if it ended while resting (i.e. the dwell stands).
    var onEnd: ((Bool) -> Void)?

    /// Converts a touch to the coordinate space the drawing is stored in.
    var logicalPoint: ((UITouch) -> CGPoint)?

    private var dwellTimer: Timer?
    private var restAnchor: CGPoint?
    /// When the pencil arrived at `restAnchor`. The rest is measured from here
    /// rather than from a one-shot timer armed on the last big move: a hand that
    /// creeps a couple of points at a time never trips the "moved" branch, so the
    /// one-shot never re-armed and the hold went unnoticed.
    private var restSince: TimeInterval = 0
    private var didDwell = false
    /// A rest that was offered and turned down (the ink isn't a shape yet). The
    /// watcher keeps looking, but waits this long before asking again so a pause
    /// halfway round a circle doesn't re-fit sixty times a second.
    private var nextAttempt: TimeInterval = 0
    /// How often the rest clock is checked.
    private static let tick: TimeInterval = 1.0 / 30.0
    private static let retryInterval: TimeInterval = 0.2

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
        isTouching = true
        points = [map(touch)]
        restAnchor = points[0]
        restSince = CACurrentMediaTime()
        nextAttempt = 0
        didDwell = false
        armTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, let map = logicalPoint else { return }
        let point = map(touch)

        // Once a shape has settled, the pencil is holding its free end. Its path
        // from here is a handle position, not more ink to fit — appending it would
        // drag the fit toward wherever the hand wandered.
        if didDwell {
            onAdjust?(point)
            return
        }

        // EVERY sample the pencil produced since the last event, not just the one
        // UIKit chose to deliver. A quick line arrives as four or five
        // `touchesMoved` calls; the fitter needs six points before it will look at
        // anything, so short strokes were being thrown away unexamined and only
        // the after-the-fact path ever snapped them.
        if let coalesced = event.coalescedTouches(for: touch), !coalesced.isEmpty {
            points.append(contentsOf: coalesced.map(map))
        } else {
            points.append(point)
        }

        guard let anchor = restAnchor else { return }
        if hypot(point.x - anchor.x, point.y - anchor.y) > holdRadius {
            // Moving again before anything settled: restart the clock from here.
            restAnchor = point
            restSince = CACurrentMediaTime()
            nextAttempt = 0
            onResume?()
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
        isTouching = false
        onEnd?(didDwell)
        didDwell = false
        restAnchor = nil
        // Never claim the touch — PencilKit owns it.
        state = .failed
    }

    /// Polls the rest clock for as long as the stroke lasts.
    ///
    /// A one-shot timer armed on the last big move looked equivalent and wasn't:
    /// it only ever got one chance per move. A pause over ink that isn't a shape
    /// yet — halfway round a circle, at the corner of a square — used up that
    /// chance, and nothing re-armed it, so the pause AFTER the shape was finished
    /// was never examined. That is "I hold and nothing happens".
    private func armTimer() {
        dwellTimer?.invalidate()
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRest() }
        }
        // Common modes, or the timer stops while the finger is scrolling anything.
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func checkRest() {
        guard !didDwell, points.count > 2, restAnchor != nil else { return }
        let now = CACurrentMediaTime()
        guard now - restSince >= minimumHold, now >= nextAttempt else { return }
        if let accepted = onDwell?(points), accepted {
            didDwell = true
        } else {
            // Not a shape yet. Stay armed — the pause that counts is the one that
            // comes once the shape is closed.
            nextAttempt = now + Self.retryInterval
        }
    }
}
