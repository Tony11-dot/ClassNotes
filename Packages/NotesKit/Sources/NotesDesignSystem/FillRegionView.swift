import ClassMateTheme
import NotesModels
import SwiftUI

/// A flooded region of a page, drawn as the polygon the fill traced.
///
/// It is drawn ABOVE the ink and still reads as being underneath it, because the
/// polygon's boundary is where the ink stopped the flood — so it only ever covers
/// the paper between the strokes, never the strokes themselves.
///
/// `holes` are the shapes the flood went round (the inner circle of a ring, the
/// cells of a table drawn inside a box). They are cut out even-odd; drawing the
/// outer ring alone painted every one of them.
public struct FillRegionView: View {
    let points: [CGPoint]
    let holes: [[CGPoint]]
    let color: ThemeColor

    public init(points: [CGPoint], holes: [[CGPoint]] = [], color: ThemeColor) {
        self.points = points
        self.holes = holes
        self.color = color
    }

    public var body: some View {
        Self.path(outline: points, holes: holes)
            .fill(color.color, style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
    }

    /// The outline and its holes as one path, for an even-odd fill — shared with
    /// the eraser's hit area so it only reaches where the paint actually is.
    public static func path(outline: [CGPoint], holes: [[CGPoint]]) -> Path {
        var path = Path()
        for ring in [outline] + holes {
            guard ring.count > 2, let first = ring.first else { continue }
            path.move(to: first)
            for point in ring.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        return path
    }
}
