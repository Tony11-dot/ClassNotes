import ClassMateTheme
import NotesModels
import SwiftUI

/// A little illustration of one writing instrument for the pen tray — a body, a
/// coloured band and the right kind of tip for its ink family. Drawn with shapes
/// (no assets) and tinted with the pen's own colour, so the tray reads at a glance
/// like a real row of pens.
public struct PenGlyphView: View {
    @Environment(\.theme) private var theme

    let preset: PenPreset
    let color: ThemeColor
    /// The selected instrument lifts out of the rail.
    let isSelected: Bool

    public init(preset: PenPreset, color: ThemeColor, isSelected: Bool) {
        self.preset = preset
        self.color = color
        self.isSelected = isSelected
    }

    private var bodyColor: Color {
        theme.isDark ? theme.surfaceRaised.color : Color.white
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let tipWidth = width * 0.3
            ZStack(alignment: .leading) {
                // Barrel
                UnevenRoundedRectangle(
                    topLeadingRadius: height * 0.28,
                    bottomLeadingRadius: height * 0.28,
                    bottomTrailingRadius: 1,
                    topTrailingRadius: 1,
                    style: .continuous
                )
                .fill(bodyColor)
                .overlay(alignment: .leading) {
                    // Grip band in the ink colour, so you can see what's loaded.
                    Rectangle()
                        .fill(color.color)
                        .frame(width: width * 0.09)
                        .padding(.vertical, height * 0.04)
                        .padding(.leading, width * 0.07)
                }
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: height * 0.28,
                        bottomLeadingRadius: height * 0.28,
                        bottomTrailingRadius: 1,
                        topTrailingRadius: 1,
                        style: .continuous
                    )
                    .strokeBorder(theme.separator.color, lineWidth: 0.5)
                )
                .frame(width: width - tipWidth, height: height)

                tip(width: tipWidth, height: height)
                    .offset(x: width - tipWidth)
            }
            .shadow(color: .black.opacity(isSelected ? 0.22 : 0.08),
                    radius: isSelected ? 4 : 2, x: isSelected ? -2 : 0, y: 1)
        }
        .accessibilityLabel(preset.displayName)
    }

    /// Each ink family gets its own nib silhouette.
    @ViewBuilder
    private func tip(width: CGFloat, height: CGFloat) -> some View {
        switch preset.ink {
        case .fountainPen:
            NibShape()
                .fill(color.color)
                .overlay(NibShape().strokeBorder(theme.separator.color, lineWidth: 0.4))
                .frame(width: width, height: height)
        case .marker where preset.isHighlighter:
            ChiselShape()
                .fill(color.withAlpha(max(0.45, color.alpha)).color)
                .frame(width: width, height: height)
        case .marker:
            ChiselShape()
                .fill(color.color)
                .frame(width: width, height: height)
        case .pencil, .crayon:
            WoodTipShape()
                .fill(color.color)
                .frame(width: width, height: height)
        case .watercolor:
            BrushTipShape()
                .fill(color.color)
                .frame(width: width, height: height)
        case .pen, .monoline:
            ConeTipShape()
                .fill(color.color)
                .frame(width: width, height: height)
        }
    }
}

/// A pointed cone — ballpoints and monoline pens.
private struct ConeTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A split nib — fountain pens.
private struct NibShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.16))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.16))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.16),
            control: CGPoint(x: rect.minX - rect.width * 0.2, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> NibShape {
        NibShape(inset: inset + amount)
    }
}

/// An angled chisel — markers and highlighters.
private struct ChiselShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A sharpened wooden point — pencil and crayon.
private struct WoodTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.midY - rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.midY + rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A soft rounded bristle head — the watercolour brush.
private struct BrushTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.12))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.1)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.12),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.1)
        )
        path.closeSubpath()
        return path
    }
}

/// The stroke preview at the top of a pen's settings panel: an S-curve drawn with
/// the pen's actual colour, width and opacity, so tuning is visible immediately.
public struct StrokePreview: View {
    @Environment(\.theme) private var theme

    let color: ThemeColor
    let width: Double
    let opacity: Double
    /// Higher stability draws a cleaner curve — the preview shows the difference.
    let stability: Int

    public init(color: ThemeColor, width: Double, opacity: Double, stability: Int) {
        self.color = color
        self.width = width
        self.opacity = opacity
        self.stability = stability
    }

    public var body: some View {
        Canvas { context, size in
            let wobble = CGFloat(PenSettings.stabilityRange.upperBound - stability) * 0.7
            var path = Path()
            let steps = 60
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let x = 14 + t * (size.width - 28)
                let base = size.height / 2 - sin(t * .pi * 2) * (size.height * 0.28)
                let jitter = sin(t * 34) * wobble
                let point = CGPoint(x: x, y: base + jitter)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(
                path,
                with: .color(color.color.opacity(opacity)),
                style: StrokeStyle(lineWidth: max(1, width * 1.6), lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: 92)
        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}
