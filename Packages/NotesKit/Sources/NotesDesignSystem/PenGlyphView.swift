import ClassMateTheme
import NotesModels
import SwiftUI

/// A little illustration of one writing instrument for the pen tray.
///
/// Every preset has its OWN silhouette — barrel profile, tail and nib — not just
/// its own colour: the tray has to tell you which pen is in your hand without
/// opening anything. The art is drawn from `PenGlyphProfile`, a data table keyed by
/// preset id, so adding an instrument stays a data change.
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

    private var profile: PenGlyphProfile { PenGlyphProfile.of(preset) }

    /// Wood and wax instruments are body-coloured; manufactured ones are pale so
    /// the ink band reads against them.
    private var barrelFill: LinearGradient {
        let base: Color = switch profile.barrel {
        case .wood, .wax: color.color.opacity(theme.isDark ? 0.55 : 0.4)
        case .translucent: color.color.opacity(0.28)
        case .round, .hex, .squat: theme.isDark ? theme.surfaceRaised.color : Color.white
        }
        return LinearGradient(
            colors: [base, base.opacity(0.82)],
            startPoint: .top, endPoint: .bottom
        )
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let tipWidth = width * profile.tipFraction
            let barrelHeight = height * profile.barrelHeightFraction

            ZStack(alignment: .leading) {
                barrel(width: width - tipWidth, height: barrelHeight)
                    .frame(height: height, alignment: .center)

                nib(width: tipWidth, height: height)
                    .offset(x: width - tipWidth)
            }
            .shadow(color: .black.opacity(isSelected ? 0.22 : 0.08),
                    radius: isSelected ? 4 : 2, x: isSelected ? -2 : 0, y: 1)
        }
        .accessibilityLabel(preset.displayName)
    }

    // MARK: - Barrel

    @ViewBuilder
    private func barrel(width: CGFloat, height: CGFloat) -> some View {
        let shape = BarrelShape(style: profile.barrel, cornerScale: height)
        shape
            .fill(barrelFill)
            .overlay(alignment: .leading) { tail(width: width, height: height) }
            .overlay(alignment: .trailing) { collar(width: width, height: height) }
            .overlay(shape.stroke(theme.separator.color, lineWidth: 0.5))
            .frame(width: width, height: height)
    }

    /// The back end: a clicker, an eraser, a wrapped stub or nothing.
    @ViewBuilder
    private func tail(width: CGFloat, height: CGFloat) -> some View {
        switch profile.tail {
        case .plain:
            EmptyView()
        case .clicker:
            Capsule()
                .fill(color.color)
                .frame(width: width * 0.1, height: height * 0.5)
                .offset(x: -width * 0.05)
        case .eraser:
            // Pink eraser + ferrule, the pencil's giveaway.
            HStack(spacing: 0) {
                UnevenRoundedRectangle(
                    topLeadingRadius: height * 0.3, bottomLeadingRadius: height * 0.3,
                    style: .continuous
                )
                .fill(Color(red: 0.94, green: 0.55, blue: 0.58))
                .frame(width: width * 0.14)
                Rectangle()
                    .fill(Color(white: 0.72))
                    .frame(width: width * 0.05)
            }
            .frame(height: height)
        case .wrap:
            // Crayon's paper sleeve: two bands around a wax stub.
            HStack(spacing: height * 0.12) {
                Rectangle().fill(Color.white.opacity(0.75)).frame(width: width * 0.055)
                Rectangle().fill(Color.white.opacity(0.75)).frame(width: width * 0.055)
            }
            .frame(height: height * 0.86)
            .padding(.leading, width * 0.14)
        }
    }

    /// The band where the barrel meets the nib — the ink colour, so a glance says
    /// what's loaded as well as which pen it is.
    @ViewBuilder
    private func collar(width: CGFloat, height: CGFloat) -> some View {
        switch profile.collar {
        case .none:
            EmptyView()
        case .band:
            Rectangle()
                .fill(color.color)
                .frame(width: width * 0.12)
        case .metal:
            LinearGradient(
                colors: [Color(white: 0.86), Color(white: 0.62)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: width * 0.2)
        }
    }

    // MARK: - Nib

    @ViewBuilder
    private func nib(width: CGFloat, height: CGFloat) -> some View {
        switch profile.tip {
        case .cone:
            ConeTipShape().fill(color.color).frame(width: width, height: height)
        case .needle:
            // A long thin needle: the fineliner reads as the precise one.
            NeedleTipShape().fill(color.color).frame(width: width, height: height)
        case .nib:
            NibShape()
                .fill(color.color)
                .overlay(NibShape().strokeBorder(theme.separator.color, lineWidth: 0.4))
                .frame(width: width, height: height)
        case .chisel:
            ChiselShape().fill(color.color).frame(width: width, height: height)
        case .wideChisel:
            ChiselShape()
                .fill(color.withAlpha(max(0.45, color.alpha)).color)
                .frame(width: width, height: height)
        case .wood:
            WoodTipShape().fill(color.color).frame(width: width, height: height)
        case .waxStub:
            WaxTipShape().fill(color.color).frame(width: width, height: height)
        case .bristle:
            BrushTipShape().fill(color.color).frame(width: width, height: height)
        }
    }
}

/// How one instrument is drawn. Each shipped pen gets a distinct combination, so
/// no two glyphs in the tray look alike.
public struct PenGlyphProfile: Sendable, Equatable {
    public enum Barrel: Sendable { case round, hex, squat, wood, wax, translucent }
    public enum Tail: Sendable { case plain, clicker, eraser, wrap }
    public enum Collar: Sendable { case none, band, metal }
    public enum Tip: Sendable {
        case cone, needle, nib, chisel, wideChisel, wood, waxStub, bristle
    }

    public let barrel: Barrel
    public let tail: Tail
    public let collar: Collar
    public let tip: Tip
    /// How much of the glyph's width the nib takes.
    public let tipFraction: CGFloat
    /// How thick the barrel is relative to the glyph — a fineliner is a sliver, a
    /// highlighter fills the row.
    public let barrelHeightFraction: CGFloat

    /// The profile for a preset. Unknown ids (a future pen, a custom one) fall back
    /// to something sensible for their ink family rather than nothing at all.
    public static func of(_ preset: PenPreset) -> PenGlyphProfile {
        if let known = table[preset.id] { return known }
        return fallback(for: preset)
    }

    private static let table: [String: PenGlyphProfile] = [
        // Slim, capped, plain: the everyday pen.
        "flow": PenGlyphProfile(
            barrel: .round, tail: .plain, collar: .band, tip: .cone,
            tipFraction: 0.26, barrelHeightFraction: 0.62
        ),
        // Clicker at the back, fatter body.
        "ballpoint": PenGlyphProfile(
            barrel: .round, tail: .clicker, collar: .band, tip: .cone,
            tipFraction: 0.22, barrelHeightFraction: 0.78
        ),
        // A sliver of a barrel and a long needle.
        "fineliner": PenGlyphProfile(
            barrel: .round, tail: .plain, collar: .none, tip: .needle,
            tipFraction: 0.34, barrelHeightFraction: 0.44
        ),
        // Wide body, metal collar, split nib.
        "fountain": PenGlyphProfile(
            barrel: .round, tail: .plain, collar: .metal, tip: .nib,
            tipFraction: 0.3, barrelHeightFraction: 0.9
        ),
        // Hexagonal wood with a pink eraser — unmistakable.
        "pencil": PenGlyphProfile(
            barrel: .hex, tail: .eraser, collar: .none, tip: .wood,
            tipFraction: 0.24, barrelHeightFraction: 0.72
        ),
        // Fat wax stub in a paper sleeve.
        "crayon": PenGlyphProfile(
            barrel: .wax, tail: .wrap, collar: .none, tip: .waxStub,
            tipFraction: 0.2, barrelHeightFraction: 1
        ),
        // Slim handle, metal ferrule, soft bristles.
        "brush": PenGlyphProfile(
            barrel: .wood, tail: .plain, collar: .metal, tip: .bristle,
            tipFraction: 0.36, barrelHeightFraction: 0.56
        ),
        // Squat marker body with a chisel.
        "marker": PenGlyphProfile(
            barrel: .squat, tail: .plain, collar: .band, tip: .chisel,
            tipFraction: 0.28, barrelHeightFraction: 0.94
        ),
        // Translucent barrel (you can see the ink level) and the widest chisel.
        "highlighter": PenGlyphProfile(
            barrel: .translucent, tail: .plain, collar: .none, tip: .wideChisel,
            tipFraction: 0.32, barrelHeightFraction: 1
        )
    ]

    private static func fallback(for preset: PenPreset) -> PenGlyphProfile {
        switch preset.ink {
        case .fountainPen:
            PenGlyphProfile(barrel: .round, tail: .plain, collar: .metal, tip: .nib,
                            tipFraction: 0.3, barrelHeightFraction: 0.9)
        case .marker:
            PenGlyphProfile(
                barrel: preset.isHighlighter ? .translucent : .squat,
                tail: .plain, collar: preset.isHighlighter ? .none : .band,
                tip: preset.isHighlighter ? .wideChisel : .chisel,
                tipFraction: 0.3, barrelHeightFraction: 0.94
            )
        case .pencil:
            PenGlyphProfile(barrel: .hex, tail: .eraser, collar: .none, tip: .wood,
                            tipFraction: 0.24, barrelHeightFraction: 0.72)
        case .crayon:
            PenGlyphProfile(barrel: .wax, tail: .wrap, collar: .none, tip: .waxStub,
                            tipFraction: 0.2, barrelHeightFraction: 1)
        case .watercolor:
            PenGlyphProfile(barrel: .wood, tail: .plain, collar: .metal, tip: .bristle,
                            tipFraction: 0.36, barrelHeightFraction: 0.56)
        case .pen, .monoline:
            PenGlyphProfile(barrel: .round, tail: .plain, collar: .band, tip: .cone,
                            tipFraction: 0.26, barrelHeightFraction: 0.66)
        }
    }
}

/// The barrel outline for a profile: rounded, faceted (hex), squat, wooden or a
/// waxy stub.
private struct BarrelShape: Shape {
    let style: PenGlyphProfile.Barrel
    let cornerScale: CGFloat

    func path(in rect: CGRect) -> Path {
        switch style {
        case .round, .translucent:
            return roundedPath(in: rect, radius: min(cornerScale * 0.3, rect.height / 2))
        case .squat:
            return roundedPath(in: rect, radius: min(cornerScale * 0.18, rect.height / 2))
        case .wood, .wax:
            return roundedPath(in: rect, radius: cornerScale * 0.06)
        case .hex:
            // A hexagonal pencil: flat top and bottom with clipped back corners.
            var path = Path()
            let notch = rect.height * 0.26
            path.move(to: CGPoint(x: rect.minX + notch, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }

    /// Rounded at the back, square where the nib joins.
    private func roundedPath(in rect: CGRect, radius: CGFloat) -> Path {
        Path(
            UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: 1,
                topTrailingRadius: 1,
                style: .continuous
            )
            .path(in: rect).cgPath
        )
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

/// A short cone that runs out into a long thin needle — the fineliner.
private struct NeedleTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder = rect.minX + rect.width * 0.42
        let thin = rect.height * 0.14
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: shoulder, y: rect.midY - thin))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - thin * 0.35))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + thin * 0.35))
        path.addLine(to: CGPoint(x: shoulder, y: rect.midY + thin))
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

/// A sharpened wooden point with graphite showing — the pencil.
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

/// A blunt, rounded-off wax end — the crayon.
private struct WaxTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let flat = rect.height * 0.3
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.midY - flat))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.midY + flat),
            control: CGPoint(x: rect.maxX + rect.width * 0.35, y: rect.midY)
        )
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
