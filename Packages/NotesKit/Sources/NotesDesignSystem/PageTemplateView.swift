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

    public init(template: PageTemplate, margin: PageMargin? = nil) {
        self.template = template
        self.margin = margin
    }

    private static let lineSpacing: CGFloat = 32
    private static let ruledTopInset: CGFloat = 64
    private static let dotSpacing: CGFloat = 28
    private static let dotRadius: CGFloat = 1.4

    public var body: some View {
        Canvas { context, size in
            let lineColor = theme.separator.color
            switch template {
            case .blank:
                break
            case .ruled:
                var y = Self.ruledTopInset
                while y < size.height {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(lineColor), lineWidth: 1)
                    y += Self.lineSpacing
                }
            case .grid:
                var x: CGFloat = Self.lineSpacing
                while x < size.width {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(lineColor), lineWidth: 0.75)
                    x += Self.lineSpacing
                }
                var y: CGFloat = Self.lineSpacing
                while y < size.height {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(lineColor), lineWidth: 0.75)
                    y += Self.lineSpacing
                }
            case .dotGrid:
                var y: CGFloat = Self.dotSpacing
                while y < size.height {
                    var x: CGFloat = Self.dotSpacing
                    while x < size.width {
                        let dot = CGRect(
                            x: x - Self.dotRadius,
                            y: y - Self.dotRadius,
                            width: Self.dotRadius * 2,
                            height: Self.dotRadius * 2
                        )
                        context.fill(Path(ellipseIn: dot), with: .color(lineColor))
                        x += Self.dotSpacing
                    }
                    y += Self.dotSpacing
                }
            }

            // Margin line (classic notebook rule down one side).
            if let margin, margin.position != .none {
                let x = margin.position == .leading ? margin.offset : size.width - margin.offset
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(marginColor(margin)), lineWidth: 1.5)
            }
        }
        .background(theme.paperColor(tone: paperTone).color)
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
