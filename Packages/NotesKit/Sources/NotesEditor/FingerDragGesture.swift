import SwiftUI
import UIKit

/// A small transparent area only a FINGER can interact with — the Apple
/// Pencil is invisible to it at the HIT-TEST level, not merely at gesture
/// recognition, so a pencil touch anywhere over it falls straight through to
/// whatever's behind (the drawing canvas). The ruler used to be draggable
/// with the Pencil too, since plain SwiftUI `DragGesture` has no touch-type
/// filter.
///
/// An earlier version of this used `UIGestureRecognizerRepresentable` with
/// `allowedTouchTypes` on the `UIPanGestureRecognizer` alone — that stops the
/// PAN from ever recognizing for a pencil touch, but does nothing about HIT
/// TESTING: the bridge's hosting view still claimed every touch landing in
/// its frame regardless of type, which is what actually delivers touches to a
/// view in the first place. A declined recognizer doesn't hand a swallowed
/// touch back to anything — the Pencil just stopped drawing wherever the
/// ruler sat. A second version then swung the other way and only claimed a
/// touch it could positively prove was a finger — which stopped the ruler
/// moving AT ALL, by either hand, the moment that proof turned out to be less
/// reliable for a small, nested, constantly-repositioned control than for the
/// canvas the pattern was copied from. `FingerHitTestView.hitTest` now claims
/// by default and only lets a touch through when it can positively prove
/// PENCIL — see its own doc comment for why that direction is the safe one.
struct FingerDragArea: UIViewRepresentable {
    struct Value {
        var translation: CGSize
    }

    var onChanged: (Value) -> Void
    var onEnded: (Value) -> Void

    func makeUIView(context: Context) -> FingerHitTestView {
        let view = FingerHitTestView()
        view.backgroundColor = .clear
        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        // Capped at one: this sits beside a `FingerRotationArea` on the same
        // ruler body (two fingers = turn), and an uncapped pan also recognizes
        // fine on two fingers — which raced the rotation for the same touches
        // and moved the ruler AND turned it from the same two-finger gesture.
        recognizer.maximumNumberOfTouches = 1
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: FingerHitTestView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    final class Coordinator: NSObject {
        var onChanged: (Value) -> Void
        var onEnded: (Value) -> Void

        init(onChanged: @escaping (Value) -> Void, onEnded: @escaping (Value) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            // WINDOW space (`nil`), not the local view's own — the ruler body
            // this is attached to is rotated to match the ruler's angle, and a
            // translation measured in a rotated view's own coordinates is
            // itself rotated relative to the screen, which silently broke
            // dragging once the ruler had been angled away from level.
            let translation = recognizer.translation(in: nil)
            let value = Value(translation: CGSize(width: translation.x, height: translation.y))
            switch recognizer.state {
            case .began, .changed:
                onChanged(value)
            case .ended, .cancelled, .failed:
                onEnded(value)
            default:
                break
            }
        }
    }
}

/// A small transparent area only TWO FINGERS can turn — same Pencil-transparent
/// hit-testing as `FingerDragArea` (reuses `FingerHitTestView`), backed by a
/// `UIRotationGestureRecognizer` instead of a pan. `UIRotationGestureRecognizer`
/// already requires two simultaneous touches to recognize at all, so no extra
/// touch-count bookkeeping is needed beyond the same touch-TYPE filter every
/// other finger-only control here uses.
struct FingerRotationArea: UIViewRepresentable {
    /// Radians, relative to wherever the gesture began — same convention as
    /// `UIRotationGestureRecognizer.rotation` itself.
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> FingerHitTestView {
        let view = FingerHitTestView()
        view.backgroundColor = .clear
        let recognizer = UIRotationGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleRotation(_:))
        )
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: FingerHitTestView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    final class Coordinator: NSObject {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void

        init(onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping (CGFloat) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onChanged(recognizer.rotation)
            case .ended, .cancelled, .failed:
                onEnded(recognizer.rotation)
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
