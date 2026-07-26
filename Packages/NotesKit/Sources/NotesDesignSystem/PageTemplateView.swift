import ClassMateTheme
import NotesModels
import SwiftUI

/// Opaque paper with the template's rule/grid/dot pattern in the theme's
/// separator color. This is the CONTENT layer — deliberately no glass, ever.
public struct PageTemplateView: View {
    @Environment(\.theme) private var theme
    @Environment(\.paperTone) private var paperTone

    let template: PageTemplate
    let margin: PageMargin?
    /// A chosen page color (hex). `nil` = the theme's paper color.
    let paperColorHex: String?

    public init(template: PageTemplate, margin: PageMargin? = nil, paperColorHex: String? = nil) {
        self.template = template
        self.margin = margin
        self.paperColorHex = paperColorHex
    }

    private static let lineSpacing: CGFloat = 32
    private static let ruledTopInset: CGFloat = 64
    private static let dotSpacing: CGFloat = 28
    private static let dotRadius: CGFloat = 1.4

    public var body: some View {
        Canvas { context, size in
            // Scale the pattern to the rendered size so it always looks like a
            // real page — a tiny preview shows the same line/dot density as the
            // full editor page (`scale` == 1 at the true 768×1024 logical size).
            let scale = size.height / PageGeometry.size.height
            // On dark paper stocks the theme separator vanishes — use a soft
            // light rule instead so lines/dots stay visible.
            let lineColor: Color = PaperPalette.isDark(paperColorHex)
                ? Color.white.opacity(0.16)
                : theme.separator.color
            let spacing = Self.lineSpacing * scale
            let topInset = Self.ruledTopInset * scale

            switch template {
            case .blank:
                break
            case .ruled, .dashed, .dotted:
                let style = ruledStrokeStyle(scale: scale)
                var y = topInset
                while y < size.height {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(lineColor), style: style)
                    y += spacing
                }
            case .grid:
                var x: CGFloat = spacing
                while x < size.width {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(lineColor), lineWidth: 0.75 * scale)
                    x += spacing
                }
                var y: CGFloat = spacing
                while y < size.height {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(lineColor), lineWidth: 0.75 * scale)
                    y += spacing
                }
            case .dotGrid:
                let dotSpacing = Self.dotSpacing * scale
                let dotRadius = max(0.5, Self.dotRadius * scale)
                var y: CGFloat = dotSpacing
                while y < size.height {
                    var x: CGFloat = dotSpacing
                    while x < size.width {
                        let dot = CGRect(
                            x: x - dotRadius, y: y - dotRadius,
                            width: dotRadius * 2, height: dotRadius * 2
                        )
                        context.fill(Path(ellipseIn: dot), with: .color(lineColor))
                        x += dotSpacing
                    }
                    y += dotSpacing
                }
            }

            // Margin line (classic notebook rule down one side).
            if let margin, margin.position != .none {
                let offset = margin.offset * scale
                let x = margin.position == .leading ? offset : size.width - offset
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(marginColor(margin)), lineWidth: 1.5 * scale)
            }
        }
        .background(paperColor)
    }

    /// Solid / dashed / dotted stroke for the ruled-line family.
    private func ruledStrokeStyle(scale: CGFloat) -> StrokeStyle {
        switch template {
        case .dashed:
            return StrokeStyle(lineWidth: 1 * scale, dash: [7 * scale, 5 * scale])
        case .dotted:
            // Round-capped zero-length dashes render as evenly spaced dots.
            return StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, dash: [0.1, 7 * scale])
        default:
            return StrokeStyle(lineWidth: 1 * scale)
        }
    }

    /// The chosen page color if set (and parseable), else the theme's paper.
    private var paperColor: Color {
        if let hex = paperColorHex, let color = ThemeColor(hex: hex) {
            return color.color
        }
        return theme.paperColor(tone: paperTone).color
    }

    /// The margin color: the user's override, else a soft classic-notebook red
    /// tuned to the paper's brightness so it reads without shouting.
    private func marginColor(_ margin: PageMargin) -> Color {
        if let hex = margin.colorHex, let color = ThemeColor(hex: hex) {
            return color.color
        }
        return theme.isDark
            ? Color(red: 0.86, green: 0.42, blue: 0.42).opacity(0.55)
            : Color(red: 0.80, green: 0.28, blue: 0.28).opacity(0.55)
    }
}
