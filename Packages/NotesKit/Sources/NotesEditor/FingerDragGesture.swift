import SwiftUI
import UIKit

/// A drag gesture only a FINGER can perform.
///
/// Plain SwiftUI `DragGesture` has no touch-type filter, so the ruler used to
/// be draggable with the Apple Pencil too — the one input that's supposed to
/// only ever draw against it, never move it. `UIGestureRecognizerRepresentable`
/// bridges a real `UIPanGestureRecognizer` into SwiftUI, which — like
/// `StrokeDwellRecognizer` elsewhere in this module — can restrict
/// `allowedTouchTypes` directly, something no SwiftUI-native gesture can do.
struct FingerDragGesture: UIGestureRecognizerRepresentable {
    struct Value {
        var translation: CGSize
        var location: CGPoint
    }

    var onChanged: (Value) -> Void
    var onEnded: (Value) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        let value = Value(
            translation: CGSize(width: translation.x, height: translation.y),
            location: recognizer.location(in: recognizer.view)
        )
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
