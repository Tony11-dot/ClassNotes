import SwiftUI
import UIKit

/// A small transparent area only a FINGER can interact with, that a one-finger
/// drag moves and a two-finger twist rotates — the ruler's whole "one hand
/// places it, two fingers turn it" vocabulary, backed by ONE view.
///
/// This exists as a single view hosting both recognizers, not two views each
/// hosting one, because two separately-overlaid `FingerHitTestView`s raced each
/// other for hit-testing: the topmost one (the rotation view, added last so its
/// two-finger gesture wasn't blocked by the pan view sitting over it) claimed
/// every non-Pencil touch, INCLUDING a plain one-finger drag, before it could
/// ever reach the pan view underneath — since `UIRotationGestureRecognizer`
/// only ever recognizes with two touches down, a single finger was claimed and
/// then simply never acted on by anything, which is exactly "the ruler can't
/// move, only rotate." Two gesture recognizers on the SAME view don't have this
/// problem — there's only one hit-test decision, not two competing ones.
///
/// The Pencil-transparent hit-testing itself is unchanged from the previous
/// two-view version — see `FingerHitTestView.hitTest`'s own doc comment for why
/// it claims by default and only lets a touch through when it can positively
/// prove Pencil.
struct FingerTransformArea: UIViewRepresentable {
    struct PanValue {
        var translation: CGSize
    }

    var onPanChanged: (PanValue) -> Void
    var onPanEnded: (PanValue) -> Void
    /// Radians, relative to wherever the two-finger gesture began — same
    /// convention as `UIRotationGestureRecognizer.rotation` itself.
    var onRotationChanged: (CGFloat) -> Void
    var onRotationEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> FingerHitTestView {
        let view = FingerHitTestView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:))
        )
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        // Capped at one: a second touch landing mid-drag should hand off to
        // rotation (see the delegate below), not have the pan keep tracking
        // both fingers at once and fight rotation for the same touches.
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator

        let rotation = UIRotationGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleRotation(_:))
        )
        rotation.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        rotation.delegate = context.coordinator

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(rotation)
        return view
    }

    func updateUIView(_ uiView: FingerHitTestView, context: Context) {
        context.coordinator.onPanChanged = onPanChanged
        context.coordinator.onPanEnded = onPanEnded
        context.coordinator.onRotationChanged = onRotationChanged
        context.coordinator.onRotationEnded = onRotationEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPanChanged: onPanChanged, onPanEnded: onPanEnded,
            onRotationChanged: onRotationChanged, onRotationEnded: onRotationEnded
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPanChanged: (PanValue) -> Void
        var onPanEnded: (PanValue) -> Void
        var onRotationChanged: (CGFloat) -> Void
        var onRotationEnded: (CGFloat) -> Void

        init(
            onPanChanged: @escaping (PanValue) -> Void, onPanEnded: @escaping (PanValue) -> Void,
            onRotationChanged: @escaping (CGFloat) -> Void, onRotationEnded: @escaping (CGFloat) -> Void
        ) {
            self.onPanChanged = onPanChanged
            self.onPanEnded = onPanEnded
            self.onRotationChanged = onRotationChanged
            self.onRotationEnded = onRotationEnded
        }

        /// Without this, UIKit's default exclusivity — only one recognizer per
        /// touch sequence unless told otherwise — would let whichever of pan or
        /// rotation recognizes FIRST silently fail the other, which is the same
        /// class of bug that made the hold-to-snap watcher never fire (see its
        /// own doc comment): a second finger landing to turn the ruler would
        /// have its rotation killed before it ever got two touches to work
        /// with, if the pan (already recognizing on the first finger) hadn't
        /// been allowed to coexist with it.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            // WINDOW space (`nil`), not the local view's own — the ruler body
            // this is attached to is rotated to match the ruler's angle, and a
            // translation measured in a rotated view's own coordinates is
            // itself rotated relative to the screen, which silently broke
            // dragging once the ruler had been angled away from level.
            let translation = recognizer.translation(in: nil)
            let value = PanValue(translation: CGSize(width: translation.x, height: translation.y))
            switch recognizer.state {
            case .began, .changed:
                onPanChanged(value)
            case .ended, .cancelled, .failed:
                onPanEnded(value)
            default:
                break
            }
        }

        @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onRotationChanged(recognizer.rotation)
            case .ended, .cancelled, .failed:
                onRotationEnded(recognizer.rotation)
            default:
                break
            }
        }
    }
}

/// A view that hands itself back UNLESS the touch at this point is positively
/// identified as the Pencil, in which case it refuses (`nil`) so the touch
/// falls through to whatever's behind (the drawing canvas).
///
/// This is deliberately "claim unless proven Pencil", not "claim only if
/// proven finger" — the first version of this view used the latter, and it
/// stopped the ruler moving AT ALL, by either hand. `PageCanvasView.hitTest`
/// (the pattern this was modelled on) gets away with the stricter "only if
/// proven finger" test because ITS fallback — claim the touch — is what you
/// want for a drawing surface when detection is ambiguous; a small, isolated
/// control like the ruler has no such luck, since claiming nothing means the
/// finger meant to drag it does nothing either. Matching the SAME bias
/// (assume yes unless positively ruled out) as the canvas, just pointed at
/// the opposite type, keeps this robust to the same edge cases without ever
/// making the control unusable.
final class FingerHitTestView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let event else { return super.hitTest(point, with: event) }
        let isPencil = event.allTouches?.contains { touch in
            guard touch.type == .pencil else { return false }
            let location = touch.location(in: self)
            let dx = location.x - point.x, dy = location.y - point.y
            return dx * dx + dy * dy < 484 // 22pt — generous on purpose, see above.
        } ?? false
        guard isPencil else { return super.hitTest(point, with: event) }
        return nil
    }
}
