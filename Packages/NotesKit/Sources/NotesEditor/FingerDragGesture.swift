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
/// ruler sat. `FingerHitTestView.hitTest` is the same "only a finger claims
/// this view" pattern `PageCanvasView` already uses for the exact same
/// reason, applied one level lower so it actually works.
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

/// A view that hands itself back for a finger touch and refuses (returns
/// `nil`) for anything else, so a Pencil touch over it is invisible to it
/// entirely and falls through to whatever's behind. Matches by proximity to
/// the queried point rather than "is any touch on the event a finger" — a
/// palm resting elsewhere on the glass must not make an unrelated touch here
/// read as a finger.
final class FingerHitTestView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let event else { return super.hitTest(point, with: event) }
        let isFinger = event.allTouches?.contains { touch in
            guard touch.type == .direct else { return false }
            let location = touch.location(in: self)
            let dx = location.x - point.x, dy = location.y - point.y
            return dx * dx + dy * dy < 4
        } ?? false
        guard isFinger else { return nil }
        return super.hitTest(point, with: event)
    }
}
