import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// The colour the paint bucket put down, drawn UNDER the ink.
///
/// Fills used to live in `PageElementsLayer` with everything else, which was wrong
/// twice over. Each element there is drawn inside a frame positioned at its own
/// box, but a fill's outline is stored in absolute page coordinates — so the
/// colour was offset by its own origin a second time and landed nowhere near the
/// shape it came from. And an element drawn over the ink means a fill that reaches
/// the whole page buries the notes, which is the only reason the flood ever had to
/// refuse an open shape.
///
/// Under the ink, both problems are gone: the paint can go as far as it reaches,
/// the writing stays on top of it, and a page-wide fill is simply a wash of
/// colour behind the page.
struct PageFillLayer: View {
    @Environment(\.theme) private var theme

    let elements: [PageElement]
    /// Displayed page size in view points.
    let displaySize: CGSize
    /// The page's logical size, so the scale is right for any paper size.
    let logicalSize: CGSize

    private var scale: CGFloat { displaySize.width / max(logicalSize.width, 1) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(elements.filter { $0.kind == .fill }) { element in
                FillRegionView(
                    points: element.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                    color: element.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accentMuted
                )
            }
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
        // The paint is scenery, not a control: every touch belongs to the ink
        // underneath it or the tool on top of it.
        .allowsHitTesting(false)
    }
}
