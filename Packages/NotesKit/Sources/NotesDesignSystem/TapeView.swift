import ClassMateTheme
import NotesModels
import SwiftUI

/// One strip of sticky tape.
///
/// Tape lives *above* the ink and covers it. Tapping lifts the strip: the fill
/// disappears so whatever was underneath shows through, and only the strip's
/// outline stays visible so it can be tapped again to put it back. That's the
/// study loop — cover the answer, quiz yourself, reveal.
public struct TapeView: View {
    @Environment(\.theme) private var theme

    let shape: TapeShape
    let pattern: TapePattern
    let color: ThemeColor
    /// Freeform / straight-line path, in the element's own coordinate space.
    let points: [CGPoint]
    let thickness: CGFloat
    let isLifted: Bool

    public init(
        shape: TapeShape,
        pattern: TapePattern,
        color: ThemeColor,
        points: [CGPoint],
        thickness: CGFloat,
        isLifted: Bool
    ) {
        self.shape = shape
        self.pattern = pattern
        self.color = color
        self.points = points
        self.thickness = thickness
        self.isLifted = isLifted
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if isLifted {
                    outline(in: geo.size)
                } else {
                    strip(in: geo.size)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isLifted)
        .accessibilityLabel(isLifted ? "Lifted tape, tap to cover" : "Tape, tap to reveal")
    }

    // MARK: - Covered

    private func strip(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let path = stripPath(in: canvasSize)
            context.fill(path, with: baseShading(canvasSize))
            // The printed motif, clipped to the strip.
            var motif = context
            motif.clip(to: path)
            draw(pattern: pattern, in: &motif, size: canvasSize)
            // A faint edge so overlapping strips stay legible.
            context.stroke(path, with: .color(edgeColor), lineWidth: 0.8)
        }
        .frame(width: size.width, height: size.height)
    }

    private func outline(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            context.stroke(
                stripPath(in: canvasSize),
                with: .color(color.withAlpha(0.85).color),
                style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])
            )
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Geometry

    /// The strip's outline in view space. A rectangle fills the frame; a drawn or
    /// straight strip is the path stroked to `thickness` and converted to an
    /// outline so patterns can be clipped into it.
    private func stripPath(in size: CGSize) -> Path {
        switch shape {
        case .rectangle:
            return Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: min(10, thickness / 3))
        case .line, .draw:
            guard points.count > 1 else {
                return Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6)
            }
            var line = Path()
            line.move(to: points[0])
            if shape == .line {
                line.addLine(to: points[points.count - 1])
            } else {
                for point in points.dropFirst() { line.addLine(to: point) }
            }
            return line.strokedPath(
                StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round)
            )
        }
    }

    // MARK: - Paint

    private var edgeColor: Color { color.withAlpha(0.55).color }
    private var motifColor: Color {
        (color.relativeLuminance < 0.5 ? Color.white : Color.black).opacity(0.22)
    }

    private func baseShading(_ size: CGSize) -> GraphicsContext.Shading {
        guard pattern == .gradient else { return .color(color.color) }
        return .linearGradient(
            Gradient(colors: [color.color, color.withAlpha(0.35).color]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)
        )
    }

    private func draw(pattern: TapePattern, in context: inout GraphicsContext, size: CGSize) {
        let unit = max(6, thickness * 0.42)
        switch pattern {
        case .solid, .gradient:
            break
        case .stripes:
            var x = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                context.stroke(path, with: .color(motifColor), lineWidth: unit * 0.55)
                x += unit * 1.5
            }
        case .checker:
            var row = 0
            var y = 0.0 as CGFloat
            while y < size.height {
                var column = 0
                var x = 0.0 as CGFloat
                while x < size.width {
                    if (row + column) % 2 == 0 {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: unit, height: unit)),
                            with: .color(motifColor)
                        )
                    }
                    x += unit
                    column += 1
                }
                y += unit
                row += 1
            }
        case .dots:
            let radius = unit * 0.22
            var y = unit / 2
            var row = 0
            while y < size.height {
                var x = unit / 2 + (row % 2 == 0 ? 0 : unit / 2)
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(motifColor)
                    )
                    x += unit
                }
                y += unit
                row += 1
            }
        case .grid:
            var x = unit
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(motifColor), lineWidth: 0.8)
                x += unit
            }
            var y = unit
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(motifColor), lineWidth: 0.8)
                y += unit
            }
        case .waves:
            var y = unit
            while y < size.height + unit {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                var x = 0.0 as CGFloat
                while x < size.width {
                    let next = x + unit
                    path.addQuadCurve(
                        to: CGPoint(x: next, y: y),
                        control: CGPoint(x: x + unit / 2, y: y + unit * 0.5)
                    )
                    x = next
                }
                context.stroke(path, with: .color(motifColor), lineWidth: 1.1)
                y += unit
            }
        case .hearts, .stars, .confetti:
            drawGlyphs(pattern, in: &context, size: size, unit: unit)
        }
    }

    private func drawGlyphs(
        _ pattern: TapePattern, in context: inout GraphicsContext, size: CGSize, unit: CGFloat
    ) {
        var generator = SeededRandom(seed: pattern.rawValue.count * 31 + 7)
        let spacing = unit * 1.6
        var y = spacing / 2
        var row = 0
        while y < size.height + spacing {
            var x = spacing / 2 + (row % 2 == 0 ? 0 : spacing / 2)
            while x < size.width + spacing {
                let center = CGPoint(x: x, y: y)
                let radius = unit * (0.28 + generator.next() * 0.12)
                switch pattern {
                case .hearts:
                    context.fill(heartPath(center: center, radius: radius), with: .color(motifColor))
                case .stars:
                    context.fill(starPath(center: center, radius: radius), with: .color(motifColor))
                default:
                    var path = Path()
                    path.move(to: center)
                    let angle = generator.next() * 2 * .pi
                    path.addLine(to: CGPoint(
                        x: center.x + cos(angle) * radius * 2,
                        y: center.y + sin(angle) * radius * 2
                    ))
                    context.stroke(
                        path, with: .color(motifColor),
                        style: StrokeStyle(lineWidth: radius * 0.6, lineCap: .round)
                    )
                }
                x += spacing
            }
            y += spacing
            row += 1
        }
    }

    private func heartPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y + radius))
        path.addCurve(
            to: CGPoint(x: center.x - radius, y: center.y - radius * 0.3),
            control1: CGPoint(x: center.x - radius * 0.6, y: center.y + radius * 0.5),
            control2: CGPoint(x: center.x - radius, y: center.y + radius * 0.2)
        )
        path.addArc(
            center: CGPoint(x: center.x - radius * 0.5, y: center.y - radius * 0.3),
            radius: radius * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false
        )
        path.addArc(
            center: CGPoint(x: center.x + radius * 0.5, y: center.y - radius * 0.3),
            radius: radius * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: center.x, y: center.y + radius),
            control1: CGPoint(x: center.x + radius, y: center.y + radius * 0.2),
            control2: CGPoint(x: center.x + radius * 0.6, y: center.y + radius * 0.5)
        )
        path.closeSubpath()
        return path
    }

    private func starPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for point in 0..<10 {
            let angle = Double(point) / 10 * 2 * .pi - .pi / 2
            let r = point % 2 == 0 ? radius : radius * 0.45
            let position = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if point == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        path.closeSubpath()
        return path
    }
}

/// A small swatch of one tape pattern, for the pattern row in the tape panel.
public struct TapePatternSwatch: View {
    let pattern: TapePattern
    let color: ThemeColor
    let isSelected: Bool

    public init(pattern: TapePattern, color: ThemeColor, isSelected: Bool) {
        self.pattern = pattern
        self.color = color
        self.isSelected = isSelected
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        TapeView(
            shape: .rectangle, pattern: pattern, color: color,
            points: [], thickness: 26, isLifted: false
        )
        .frame(width: 74, height: 30)
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                isSelected ? theme.accent.color : theme.separator.color,
                lineWidth: isSelected ? 2 : 0.5
            )
        )
        .accessibilityLabel("\(pattern.displayName) tape")
    }
}
