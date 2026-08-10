import ClassMateTheme
import NotesModels
import SwiftUI

/// A flooded region of a page, drawn as the polygon the fill traced.
///
/// It is drawn ABOVE the ink and still reads as being underneath it, because the
/// polygon's boundary is where the ink stopped the flood — so it only ever covers
/// the paper between the strokes, never the strokes themselves.
public struct FillRegionView: View {
    let points: [CGPoint]
    let color: ThemeColor

    public init(points: [CGPoint], color: ThemeColor) {
        self.points = points
        self.color = color
    }

    public var body: some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        .fill(color.color)
        .allowsHitTesting(false)
    }
}
