import ClassMateTheme
import NotesModels
import SwiftUI

/// Opaque paper with the template's printed pattern, drawn in the page's line
/// color (or the theme's separator when that's "auto"). This is the CONTENT
/// layer — deliberately no glass, ever.
///
/// Geometry is expressed in the page's own logical space and scaled to whatever
/// size the view is given, so a 90 pt thumbnail shows the same rule density as
/// the full editor page.
public struct PageTemplateView: View {
    @Environment(\.theme) private var theme
    @Environment(\.paperTone) private var paperTone

    private let style: PageStyle

    public init(style: PageStyle) {
        self.style = style
    }

    /// Legacy shape (template + margin + paper color) — a classic portrait page.
    public init(template: PageTemplate, margin: PageMargin? = nil, paperColorHex: String? = nil) {
        self.style = PageStyle(
            template: template,
            margin: margin ?? PageMargin(position: .none),
            paperColorHex: paperColorHex
        )
    }

    private static let ruledTopInset: CGFloat = 64
    private static let dotSpacingRatio: CGFloat = 0.875   // 28 pt at the 32 pt rule

    public var body: some View {
        Canvas { context, size in
            let logical = style.logicalSize
            let scale = size.height / max(logical.height, 1)
            let spacing = PageLineSpacing.baseRuleSpacing
                * PageLineSpacing.scale(steps: style.lineSpacingSteps) * scale
            let lineColor = resolvedLineColor
            let strong = lineColor.opacity(1)
            let soft = lineColor.opacity(0.55)

            switch style.template {
            case .blank:
                break
            case .ruled, .dashed, .dotted:
                drawRules(context, size: size, spacing: spacing, scale: scale,
                          color: strong, from: Self.ruledTopInset * scale)
            case .grid:
                drawGrid(context, size: size, spacing: spacing, scale: scale, color: strong)
            case .dotGrid:
                drawDots(context, size: size,
                         spacing: spacing * Self.dotSpacingRatio, scale: scale, color: strong)
            case .cornell:
                drawCornell(context, size: size, spacing: spacing, scale: scale,
                            color: strong, accent: soft)
            case .todo:
                drawChecklist(context, size: size, spacing: spacing, scale: scale, color: strong)
            case .weekly:
                drawWeekly(context, size: size, scale: scale, color: strong, soft: soft)
            case .music:
                drawMusic(context, size: size, scale: scale, color: strong)
            case .isometric:
                drawIsometric(context, size: size, spacing: spacing, scale: scale, color: soft)
            case .storyboard:
                drawStoryboard(context, size: size, scale: scale, color: strong, soft: soft)
            case .graph:
                drawGraph(context, size: size, spacing: spacing, scale: scale,
                          color: soft, major: strong)
            case .log:
                drawLog(context, size: size, scale: scale, color: soft, major: strong)
            }

            drawMargin(context, size: size, scale: scale)
        }
        .background(paperColor)
    }

    // MARK: - Colors

    /// The chosen page color if set (and parseable), else the theme's paper.
    private var paperColor: Color {
        if let hex = style.paperColorHex, let color = ThemeColor(hex: hex) {
            return color.color
        }
        return theme.paperColor(tone: paperTone).color
    }

    /// The rule color: the user's choice, else the theme separator — swapped for a
    /// soft light rule on dark paper stocks, where the separator would vanish.
    private var resolvedLineColor: Color {
        if let hex = style.lineColorHex, let color = ThemeColor(hex: hex) {
            return color.color
        }
        return PaperPalette.isDark(style.paperColorHex)
            ? Color.white.opacity(0.16)
            : theme.separator.color
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

    // MARK: - Primitives

    private func ruledStrokeStyle(scale: CGFloat) -> StrokeStyle {
        switch style.template {
        case .dashed:
            return StrokeStyle(lineWidth: 1 * scale, dash: [7 * scale, 5 * scale])
        case .dotted:
            // Round-capped zero-length dashes render as evenly spaced dots.
            return StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, dash: [0.1, 7 * scale])
        default:
            return StrokeStyle(lineWidth: 1 * scale)
        }
    }

    private func line(
        _ context: GraphicsContext, from: CGPoint, to: CGPoint,
        color: Color, width: CGFloat
    ) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private func drawRules(
        _ context: GraphicsContext, size: CGSize, spacing: CGFloat, scale: CGFloat,
        color: Color, from top: CGFloat, to bottom: CGFloat? = nil,
        leading: CGFloat = 0, trailing: CGFloat? = nil
    ) {
        let style = ruledStrokeStyle(scale: scale)
        let end = bottom ?? size.height
        let right = trailing ?? size.width
        var y = top
        while y < end {
            var path = Path()
            path.move(to: CGPoint(x: leading, y: y))
            path.addLine(to: CGPoint(x: right, y: y))
            context.stroke(path, with: .color(color), style: style)
            y += spacing
        }
    }

    private func drawGrid(
        _ context: GraphicsContext, size: CGSize, spacing: CGFloat,
        scale: CGFloat, color: Color
    ) {
        let width = 0.75 * scale
        var x = spacing
        while x < size.width {
            line(context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height),
                 color: color, width: width)
            x += spacing
        }
        var y = spacing
        while y < size.height {
            line(context, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y),
                 color: color, width: width)
            y += spacing
        }
    }

    private func drawDots(
        _ context: GraphicsContext, size: CGSize, spacing: CGFloat,
        scale: CGFloat, color: Color
    ) {
        let radius = max(0.5, 1.4 * scale)
        var y = spacing
        while y < size.height {
            var x = spacing
            while x < size.width {
                let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: dot), with: .color(color))
                x += spacing
            }
            y += spacing
        }
    }

    // MARK: - Study templates

    /// Cue column down the left, a summary band along the bottom, rules between.
    private func drawCornell(
        _ context: GraphicsContext, size: CGSize, spacing: CGFloat, scale: CGFloat,
        color: Color, accent: Color
    ) {
        let cueX = size.width * 0.28
        let summaryY = size.height * 0.82
        let headerY = min(56 * scale, size.height * 0.08)
        drawRules(context, size: size, spacing: spacing, scale: scale, color: accent,
                  from: headerY + spacing, to: summaryY, leading: cueX)
        line(context, from: CGPoint(x: cueX, y: headerY), to: CGPoint(x: cueX, y: summaryY),
             color: color, width: 1.2 * scale)
        line(context, from: CGPoint(x: 0, y: headerY), to: CGPoint(x: size.width, y: headerY),
             color: color, width: 1.2 * scale)
        line(context, from: CGPoint(x: 0, y: summaryY), to: CGPoint(x: size.width, y: summaryY),
             color: color, width: 1.2 * scale)
    }

    /// Ruled lines, each with an empty checkbox at the left.
    private func drawChecklist(
        _ context: GraphicsContext, size: CGSize, spacing: CGFloat,
        scale: CGFloat, color: Color
    ) {
        let boxSide = min(spacing * 0.5, 16 * scale)
        let inset = 28 * scale
        var y = Self.ruledTopInset * scale
        while y < size.height {
            line(context, from: CGPoint(x: inset + boxSide + 10 * scale, y: y),
                 to: CGPoint(x: size.width - inset, y: y), color: color, width: 1 * scale)
            let box = CGRect(x: inset, y: y - boxSide - 2 * scale, width: boxSide, height: boxSide)
            context.stroke(
                Path(roundedRect: box, cornerRadius: 2.5 * scale),
                with: .color(color), lineWidth: 1.1 * scale
            )
            y += spacing
        }
    }

    /// A week grid: a day column per row with a header band.
    private func drawWeekly(
        _ context: GraphicsContext, size: CGSize, scale: CGFloat, color: Color, soft: Color
    ) {
        let headerHeight = min(64 * scale, size.height * 0.09)
        let rows = 7
        let rowHeight = (size.height - headerHeight) / CGFloat(rows)
        let labelX = 34 * scale
        line(context, from: CGPoint(x: 0, y: headerHeight), to: CGPoint(x: size.width, y: headerHeight),
             color: color, width: 1.4 * scale)
        line(context, from: CGPoint(x: labelX, y: headerHeight), to: CGPoint(x: labelX, y: size.height),
             color: soft, width: 1 * scale)
        let days = ["M", "T", "W", "T", "F", "S", "S"]
        for row in 0..<rows {
            let y = headerHeight + CGFloat(row) * rowHeight
            if row > 0 {
                line(context, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y),
                     color: soft, width: 1 * scale)
            }
            let label = Text(days[row])
                .font(.dsSystem(size: max(6, 15 * scale), weight: .semibold))
                .foregroundStyle(color)
            context.draw(label, at: CGPoint(x: labelX / 2, y: y + rowHeight / 2), anchor: .center)
        }
    }

    // MARK: - Creative templates

    /// Repeating five-line staves with a rest between systems.
    private func drawMusic(
        _ context: GraphicsContext, size: CGSize, scale: CGFloat, color: Color
    ) {
        let lineGap = 9 * scale
        let staffHeight = lineGap * 4
        let systemGap = staffHeight + 34 * scale
        let inset = 32 * scale
        var top = 60 * scale
        while top + staffHeight < size.height {
            for index in 0..<5 {
                let y = top + CGFloat(index) * lineGap
                line(context, from: CGPoint(x: inset, y: y),
                     to: CGPoint(x: size.width - inset, y: y), color: color, width: 0.9 * scale)
            }
            // Bar lines at either end of the system.
            for x in [inset, size.width - inset] {
                line(context, from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: top + staffHeight),
                     color: color, width: 1.1 * scale)
            }
            top += systemGap
        }
    }

    /// Vertical rules plus ±30° diagonals — a true isometric drawing grid.
    private func drawIsometric(
        _ context: GraphicsContext, size: CGSize, spacing: CGFloat,
        scale: CGFloat, color: Color
    ) {
        let width = 0.7 * scale
        var x = 0.0 as CGFloat
        while x <= size.width {
            line(context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height),
                 color: color, width: width)
            x += spacing
        }
        // tan(30°) ≈ 0.5774 — the diagonals march down as they cross the page.
        let slope: CGFloat = 0.5773502692
        let step = spacing / 0.8660254
        var offset = -size.width * slope
        while offset <= size.height + size.width * slope {
            line(context, from: CGPoint(x: 0, y: offset),
                 to: CGPoint(x: size.width, y: offset + size.width * slope),
                 color: color, width: width)
            line(context, from: CGPoint(x: 0, y: offset + size.width * slope),
                 to: CGPoint(x: size.width, y: offset),
                 color: color, width: width)
            offset += step
        }
    }

    /// Frames with a caption rule under each — for storyboards and comics.
    private func drawStoryboard(
        _ context: GraphicsContext, size: CGSize, scale: CGFloat, color: Color, soft: Color
    ) {
        let columns = 2
        let rows = 3
        let inset = 32 * scale
        let gap = 20 * scale
        let cellWidth = (size.width - inset * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (size.height - inset * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let frameHeight = cellHeight * 0.74
        for row in 0..<rows {
            for column in 0..<columns {
                let origin = CGPoint(
                    x: inset + CGFloat(column) * (cellWidth + gap),
                    y: inset + CGFloat(row) * (cellHeight + gap)
                )
                let frame = CGRect(origin: origin, size: CGSize(width: cellWidth, height: frameHeight))
                context.stroke(
                    Path(roundedRect: frame, cornerRadius: 6 * scale),
                    with: .color(color), lineWidth: 1.2 * scale
                )
                var captionY = frame.maxY + 12 * scale
                while captionY < origin.y + cellHeight {
                    line(context, from: CGPoint(x: frame.minX, y: captionY),
                         to: CGPoint(x: frame.maxX, y: captionY), color: soft, width: 0.8 * scale)
                    captionY += 14 * scale
                }
            }
        }
    }

    /// Fine graph paper with a heavier line every fifth division and centered axes.
    private func drawGraph(
        _ context: GraphicsContext, size: CGSize, spacing: CGFloat,
        scale: CGFloat, color: Color, major: Color
    ) {
        let minor = spacing / 5
        var index = 0
        var x = 0.0 as CGFloat
        while x <= size.width {
            let isMajor = index % 5 == 0
            line(context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height),
                 color: isMajor ? major : color, width: (isMajor ? 0.9 : 0.5) * scale)
            x += minor
            index += 1
        }
        index = 0
        var y = 0.0 as CGFloat
        while y <= size.height {
            let isMajor = index % 5 == 0
            line(context, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y),
                 color: isMajor ? major : color, width: (isMajor ? 0.9 : 0.5) * scale)
            y += minor
            index += 1
        }
        line(context, from: CGPoint(x: size.width / 2, y: 0),
             to: CGPoint(x: size.width / 2, y: size.height), color: major, width: 1.6 * scale)
        line(context, from: CGPoint(x: 0, y: size.height / 2),
             to: CGPoint(x: size.width, y: size.height / 2), color: major, width: 1.6 * scale)
    }

    /// Semi-log paper: linear verticals, logarithmic horizontals per decade.
    private func drawLog(
        _ context: GraphicsContext, size: CGSize, scale: CGFloat, color: Color, major: Color
    ) {
        let decades = 4
        let decadeHeight = size.height / CGFloat(decades)
        var x = 0.0 as CGFloat
        let columnSpacing = size.width / 20
        while x <= size.width {
            line(context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height),
                 color: color, width: 0.5 * scale)
            x += columnSpacing
        }
        for decade in 0...decades {
            let base = CGFloat(decade) * decadeHeight
            line(context, from: CGPoint(x: 0, y: base), to: CGPoint(x: size.width, y: base),
                 color: major, width: 1.2 * scale)
            guard decade < decades else { continue }
            for step in 2...9 {
                let fraction = log10(CGFloat(step))
                let y = base + fraction * decadeHeight
                line(context, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y),
                     color: color, width: 0.5 * scale)
            }
        }
    }

    // MARK: - Margin

    private func drawMargin(_ context: GraphicsContext, size: CGSize, scale: CGFloat) {
        let margin = style.margin
        guard margin.position != .none else { return }
        let offset = margin.offset * scale
        let x = margin.position == .leading ? offset : size.width - offset
        line(context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height),
             color: marginColor(margin), width: 1.5 * scale)
    }
}

extension PageTemplateView {
    /// The view sized to a page's own aspect ratio — every page surface in the app
    /// (editor, thumbnails, previews, viewer) uses this so proportions agree.
    public static func aspectRatio(of style: PageStyle) -> CGFloat {
        let size = style.logicalSize
        return size.width / max(size.height, 1)
    }
}
