import CoreGraphics
import Foundation
import Testing
@testable import NotesEditor
@testable import NotesModels

@Suite("Repro: circle held for real-world duration")
struct HoldReproTests {
    @Test("A jittery circle plus a long resting tail still live-snaps")
    func longHoldCircleStillSnaps() {
        let center = CGPoint(x: 200, y: 200)
        let radius: CGFloat = 80
        var raw: [CGPoint] = []
        // Draw the circle quickly: ~40 samples with small tremor.
        for i in 0...40 {
            let t = CGFloat(i) / 40 * 2 * .pi
            let jitter: CGFloat = (i % 2 == 0) ? 1.5 : -1.5
            raw.append(CGPoint(x: center.x + (radius + jitter) * cos(t), y: center.y + (radius + jitter) * sin(t)))
        }
        // Now hold still at the closing point for ~3 seconds at 120Hz = 360 samples,
        // with tremor amplitude comparable to typical hand tremor (a few points).
        let restPoint = raw.last!
        for i in 0..<360 {
            let angle = CGFloat(i) * 0.3
            let tremor: CGFloat = 3.0
            raw.append(CGPoint(x: restPoint.x + tremor * cos(angle), y: restPoint.y + tremor * sin(angle)))
        }

        let smoothed = StrokeSmoothing.smooth(raw, window: 7)
        let snap = ShapeSnapper.liveSnap(smoothed)
        #expect(snap != nil, "a held circle with a realistic resting tail should live-snap")
        if let snap {
            #expect(snap.shape == .ellipse)
        }
    }
}
