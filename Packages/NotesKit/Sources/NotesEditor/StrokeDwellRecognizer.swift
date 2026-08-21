import CoreGraphics
import PencilKit
import QuartzCore
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
final class StrokeDwellRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// How far the pencil may drift and still count as resting, in the PAGE'S
    /// LOGICAL space.
    ///
    /// A page is usually shown smaller than its logical size (`PageCanvasView`
    /// fits it to the available width), and `logicalPoint` divides every touch
    /// by that same fit scale — so a fixed logical radius shrinks in real,
    /// on-screen terms exactly when the page is zoomed out, which is most of
    /// the time. `zoomScale` (read live, the same way `logicalPoint` is) is
    /// what keeps the tolerance a constant SCREEN distance instead: the radius
    /// actually compared against is `holdRadius / zoomScale`. Without this, a
    /// hand that would comfortably hold still on a 1:1 page drifted the shape
    /// snap open on any page shown at less than full size.
    var holdRadius: CGFloat = ShapeSnapper.holdRadius
    /// A real hold is never perfectly still — the hand tremors continuously,
    /// often past `holdRadius` itself. The first version of this watcher reset
    /// BOTH the anchor and the rest clock the instant any single sample crossed
    /// `holdRadius`, which is why the dwell only ever seemed to fire on release:
    /// tremor with an amplitude anywhere near the radius made nearly every
    /// sample look like "moved again," so the 0.28s clock could never actually
    /// accumulate. `escapeRadius` is a second, larger radius — only a sample
    /// past THIS one is treated as a genuine, deliberate move; ordinary tremor
    /// inside it is absorbed (the anchor doesn't move, the clock doesn't
    /// restart), which is what holding still like any other app actually
    /// requires of a hand that's never truly motionless.
    private static let escapeMultiplier: CGFloat = 2.2
    /// The canvas's current zoom, read fresh on every sample — see `holdRadius`.
    var zoomScale: (() -> CGFloat)?
    /// How long it must rest before the shape settles. Shorter than the
    /// stroke-timing threshold was: the user is watching it happen now, so the
    /// wait is felt rather than merely measured.
    ///
    /// 0.28s was short enough to fire on an entirely ordinary pause mid-letter
    /// — crossing a "t", dotting an "i", or just resting a beat before the next
    /// stroke of a straight-sided letter (l, t, i, 1, L…) easily rests longer
    /// than that. Once a dwell is ACCEPTED, every pencil sample after it is
    /// read as a handle moving a shape (`touchesMoved`'s `didDwell` branch),
    /// not as more ink — so a false trigger mid-letter doesn't just show a
    /// wrong preview, it steals the rest of the stroke, which is what "writing
    /// snaps to a line/angle" and "writing doesn't stick" both actually were.
    /// Raised so an ordinary writing pause reads as ink, not a hold — a
    /// deliberate hold-to-snap is felt as a distinct, longer pause against
    /// this.
    var minimumHold: TimeInterval = 0.45

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
    /// The path so far, on every sample, while it is still ordinary ink.
    ///
    /// This is how the straight-edge rules a line WHILE it is being drawn rather
    /// than a beat after it is finished. Returning true means something has taken
    /// the stroke over: the watcher stops offering it dwells and takes the touch,
    /// so nothing else can act on it either.
    var onProgress: (([CGPoint]) -> Bool)?
    /// The pencil moved off again before anything settled — drop any preview.
    var onResume: (() -> Void)?
    /// The stroke ended. `true` if it ended while resting (i.e. the dwell stands).
    var onEnd: ((Bool) -> Void)?

    /// Converts a touch to the coordinate space the drawing is stored in.
    var logicalPoint: ((UITouch) -> CGPoint)?

    private var dwellTimer: Timer?
    /// The one touch this watcher is following. A second finger landing on the
    /// page (the hand steadying it, a palm) used to be indistinguishable from the
    /// pencil moving, which is how a hold turned into a jump across the page.
    private weak var trackedTouch: UITouch?
    private var restAnchor: CGPoint?
    /// When the pencil arrived at `restAnchor`. The rest is measured from here
    /// rather than from a one-shot timer armed on the last big move: a hand that
    /// creeps a couple of points at a time never trips the "moved" branch, so the
    /// one-shot never re-armed and the hold went unnoticed.
    private var restSince: TimeInterval = 0
    private var didDwell = false
    /// Whether this gesture took the touch (see `claimTouch`).
    private var didClaim = false
    /// Whether the stroke has been taken over live — the straight-edge is ruling
    /// it — in which case it is no longer a candidate for a shape snap.
    private var isTakenOver = false
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
        // Round 13's theory, after touch-type widening (round 12) produced
        // ZERO change — not even a single haptic on any hold, of any length.
        // That result rules out touch delivery being filtered at the door and
        // points one layer deeper: UIKit's default gesture EXCLUSIVITY. The
        // instant PencilKit's own `drawingGestureRecognizer` recognizes a
        // stroke has begun — which happens almost immediately, well under the
        // 0.28s `minimumHold` this recognizer waits for — UIKit's default
        // behaviour is to force every SIBLING recognizer still sitting in
        // `.possible` straight to `.failed`, with no delegate callback and no
        // chance to opt out. This recognizer never asked to be exempted, so it
        // was very likely being silently failed within the first touch sample
        // of EVERY stroke, long before `checkRest()` ever got a chance to
        // fire — which explains "doesn't matter how long I hold" perfectly:
        // the recognizer wasn't losing a timing race, it was being killed
        // before the race started. Declaring itself as its own delegate and
        // always allowing simultaneous recognition keeps this recognizer alive
        // for the whole stroke, purely OBSERVING (see the class doc — it still
        // never inks anything, never blocks anything) alongside whatever else
        // is recognizing. The one place this recognizer DOES need to win
        // (taking over once a shape settles) is handled separately and
        // explicitly, by disabling `drawingGestureRecognizer.isEnabled`
        // (`suppressLiveInk`), not by relying on exclusivity — so this change
        // doesn't touch that behaviour at all.
        delegate = self
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // Already following one — everything else on the glass is the hand.
        guard trackedTouch == nil, let touch = touches.first, let map = logicalPoint else { return }
        trackedTouch = touch
        isTouching = true
        points = [map(touch)]
        restAnchor = points[0]
        restSince = CACurrentMediaTime()
        nextAttempt = 0
        didDwell = false
        isTakenOver = false
        armTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first(where: { $0 === trackedTouch }),
              let map = logicalPoint else { return }
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

        // Offer the growing path to whatever wants to act on it live. The ruler
        // does: the line has to come out straight as it is drawn, not be
        // straightened afterwards.
        if let onProgress, onProgress(points), !isTakenOver {
            isTakenOver = true
            claimTouch()
        }

        guard let anchor = restAnchor else { return }
        let effectiveRadius = holdRadius / max(zoomScale?() ?? 1, 0.05)
        if hypot(point.x - anchor.x, point.y - anchor.y) > effectiveRadius * Self.escapeMultiplier {
            // A genuine move away, not tremor: the anchor follows and the clock
            // restarts from here.
            restAnchor = point
            restSince = CACurrentMediaTime()
            nextAttempt = 0
            // A stroke the ruler is already ruling has no preview to drop — and
            // dropping one on every sample would erase the ruled line as fast as
            // it was drawn.
            if !isTakenOver { onResume?() }
        }
        // Otherwise: ordinary tremor within the escape radius. Leaving the
        // anchor and the clock alone is what lets a hand that never stops
        // shaking still accumulate a hold — see `escapeMultiplier` above.
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard touches.contains(where: { $0 === trackedTouch }) else { return }
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard touches.contains(where: { $0 === trackedTouch }) else { return }
        finish()
    }

    /// UIKit's own last word on a gesture, whatever route it took to get here.
    ///
    /// This is the safety net, and it is not optional. A recognizer that another
    /// one beats to the touch is reset WITHOUT `touchesCancelled` — so `finish`
    /// was skipped, `isTouching` stayed true for the rest of the session, and
    /// everything downstream that waits for the pencil to lift (the ink pass,
    /// undo steps, beautification) waited forever. If a shape happened to be held
    /// at the time, the canvas stayed muted too: the pencil stopped drawing
    /// altogether and the page scrolled under it instead.
    override func reset() {
        super.reset()
        if isTouching { finish(claiming: false) }
        dwellTimer?.invalidate()
        dwellTimer = nil
        trackedTouch = nil
        restAnchor = nil
    }

    /// Takes the touch away from every other recognizer tracking it.
    ///
    /// Only ever called once a dwell has been ACCEPTED, i.e. the pencil is
    /// deliberately holding a settled shape. Muting PencilKit at that moment
    /// leaves the touch free for the enclosing scroll view's pan, which would
    /// drag the page out from under the shape being sized. Moving to `.began`
    /// makes this the recognizer in charge for the rest of the gesture, so
    /// nothing else can pick it up.
    private func claimTouch() {
        guard state == .possible else { return }
        didClaim = true
        state = .began
    }

    private func finish(claiming: Bool = true) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        guard isTouching else { return }
        isTouching = false
        trackedTouch = nil
        onEnd?(didDwell || isTakenOver)
        didDwell = false
        isTakenOver = false
        restAnchor = nil
        // Ordinarily the touch was never claimed — PencilKit owns it — and the
        // watcher bows out with `.failed`. A held shape is the exception: it took
        // the touch, so it has to end it properly.
        guard claiming else { return }
        if didClaim {
            didClaim = false
            state = .ended
        } else {
            state = .failed
        }
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
        guard !didDwell, !isTakenOver, points.count > 2, restAnchor != nil else { return }
        let now = CACurrentMediaTime()
        guard now - restSince >= minimumHold, now >= nextAttempt else { return }
        if let accepted = onDwell?(points), accepted {
            didDwell = true
            claimTouch()
        } else {
            // Not a shape yet. Stay armed — the pause that counts is the one that
            // comes once the shape is closed.
            nextAttempt = now + Self.retryInterval
        }
    }
}
