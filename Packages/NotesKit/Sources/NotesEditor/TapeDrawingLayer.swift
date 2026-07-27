import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// The surface that lays tape down.
///
/// Only present while the tape tool is selected — the canvas hands the pencil over
/// (its drawing gesture is off in tape mode), so a drag here becomes a strip
/// instead of a stroke. The strip previews live under the pencil and is committed
/// to the manifest on release.
struct TapeDrawingLayer: View {
    @Environment(\.theme) private var theme

    let toolState: ToolState
    /// Displayed page size in view points.
    let displaySize: CGSize
    /// The page's logical size, for converting the drag into page coordinates.
    let logicalSize: CGSize
    let onCommit: ([CGPoint]) -> Void

    @State private var points: [CGPoint] = []

    private var scale: CGFloat { displaySize.width / max(logicalSize.width, 1) }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            if points.count > 1 {
                preview
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if points.isEmpty { points = [value.startLocation] }
                    points.append(value.location)
                }
                .onEnded { _ in
                    let drawn = points
                    points = []
                    guard drawn.count > 1 else { return }
                    // Convert the drag into the page's logical space.
                    onCommit(drawn.map { CGPoint(x: $0.x / scale, y: $0.y / scale) })
                }
        )
    }

    /// A live preview of the strip being laid, in the tape's own colour/pattern.
    @ViewBuilder
    private var preview: some View {
        let color = toolState.tapeColor(theme: theme)
        let thickness = toolState.tapeThickness * scale
        switch toolState.tapeShape {
        case .rectangle:
            let rect = boundingRect
            TapeView(
                shape: .rectangle, pattern: toolState.tapePattern, color: color,
                points: [], thickness: thickness, isLifted: false
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        case .line, .draw:
            TapeView(
                shape: toolState.tapeShape, pattern: toolState.tapePattern, color: color,
                points: points, thickness: thickness, isLifted: false
            )
            .frame(width: displaySize.width, height: displaySize.height)
            .allowsHitTesting(false)
        }
    }

    private var boundingRect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(
            x: min(first.x, last.x), y: min(first.y, last.y),
            width: abs(last.x - first.x), height: abs(last.y - first.y)
        )
    }
}

/// The surface that drops text boxes: while the text tool is selected, a tap
/// anywhere places an empty box there and opens the keyboard in it.
struct TextPlacementLayer: View {
    let displaySize: CGSize
    let logicalSize: CGSize
    let onPlace: (CGPoint) -> Void

    private var scale: CGFloat { displaySize.width / max(logicalSize.width, 1) }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: displaySize.width, height: displaySize.height)
            .onTapGesture { location in
                onPlace(CGPoint(x: location.x / scale, y: location.y / scale))
            }
    }
}
