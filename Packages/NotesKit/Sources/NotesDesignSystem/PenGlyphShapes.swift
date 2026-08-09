import ClassMateTheme
import NotesModels
import SwiftUI

// The vector parts the pen tray is drawn from: one barrel silhouette per
// instrument body, one shape per nib, and the stroke preview the settings panel
// uses. Split out of `PenGlyphView` so the art and the assembly stay legible
// separately.

// MARK: - Barrel silhouettes

/// The barrel outline. Real pens are not rounded rectangles: they dome at the
/// back, carry a belly, and narrow into a shoulder before the nib — and a brush
/// handle does the opposite, tapering backward to a point.
struct BarrelShape: InsettableShape {
    let body: PenGlyphProfile.Body
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> BarrelShape {
        BarrelShape(body: body, inset: inset + amount)
    }

    /// Dispatch only — each silhouette is its own function so the shapes stay
    /// readable and one instrument can be retuned without scrolling past eight
    /// others.
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        switch body {
        case .tapered, .slim: return taperedPath(in: r, slim: body == .slim)
        case .clicker: return clickerPath(in: r)
        case .fountain: return fountainPath(in: r)
        case .hex: return hexPath(in: r)
        case .wax: return waxPath(in: r)
        case .handle: return handlePath(in: r)
        case .marker: return markerPath(in: r)
        case .highlighter: return highlighterPath(in: r)
        }
    }

    /// Domed back, straight sides, narrowing into a shoulder at the nib.
    private func taperedPath(in r: CGRect, slim: Bool) -> Path {
        let dome = r.width * (slim ? 0.06 : 0.10)
        let shoulder = r.height * 0.16
        var path = Path()
        path.move(to: CGPoint(x: r.minX + dome, y: r.minY))
        path.addQuadCurve(
            to: CGPoint(x: r.minX + dome, y: r.maxY),
            control: CGPoint(x: r.minX - dome * 0.7, y: r.midY)
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - shoulder))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + shoulder))
        path.closeSubpath()
        return path
    }

    /// Squared-off back for the plunger to sit behind.
    private func clickerPath(in r: CGRect) -> Path {
        let back = r.width * 0.04
        let shoulder = r.height * 0.14
        var path = Path()
        path.move(to: CGPoint(x: r.minX + back, y: r.minY + r.height * 0.14))
        path.addQuadCurve(
            to: CGPoint(x: r.minX, y: r.midY),
            control: CGPoint(x: r.minX, y: r.minY + r.height * 0.05)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.minX + back, y: r.maxY - r.height * 0.14),
            control: CGPoint(x: r.minX, y: r.maxY - r.height * 0.05)
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - shoulder))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + shoulder))
        path.closeSubpath()
        return path
    }

    /// A belly: widest a third of the way along, narrowing to the section.
    private func fountainPath(in r: CGRect) -> Path {
        let shoulder = r.height * 0.22
        var path = Path()
        path.move(to: CGPoint(x: r.minX + r.width * 0.06, y: r.minY + r.height * 0.08))
        path.addQuadCurve(
            to: CGPoint(x: r.minX + r.width * 0.06, y: r.maxY - r.height * 0.08),
            control: CGPoint(x: r.minX - r.width * 0.05, y: r.midY)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.maxX, y: r.maxY - shoulder),
            control: CGPoint(x: r.minX + r.width * 0.55, y: r.maxY + r.height * 0.06)
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: r.minX + r.width * 0.06, y: r.minY + r.height * 0.08),
            control: CGPoint(x: r.minX + r.width * 0.55, y: r.minY - r.height * 0.06)
        )
        path.closeSubpath()
        return path
    }

    /// The blunt, unsharpened end is cut square with clipped corners.
    private func hexPath(in r: CGRect) -> Path {
        let notch = r.height * 0.22
        var path = Path()
        path.move(to: CGPoint(x: r.minX + notch * 0.5, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + notch * 0.5, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.midY))
        path.closeSubpath()
        return path
    }

    /// A plain stub with a rounded-off back.
    private func waxPath(in r: CGRect) -> Path {
        let round = r.height * 0.16
        var path = Path()
        path.move(to: CGPoint(x: r.minX + round, y: r.minY))
        path.addQuadCurve(
            to: CGPoint(x: r.minX + round, y: r.maxY),
            control: CGPoint(x: r.minX - round * 0.4, y: r.midY)
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.closeSubpath()
        return path
    }

    /// Tapers BACKWARD to a point, then swells into the ferrule.
    private func handlePath(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.midY - r.height * 0.14))
        path.addQuadCurve(
            to: CGPoint(x: r.maxX, y: r.minY),
            control: CGPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.06)
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addQuadCurve(
            to: CGPoint(x: r.minX, y: r.midY + r.height * 0.14),
            control: CGPoint(x: r.minX + r.width * 0.62, y: r.maxY - r.height * 0.06)
        )
        path.closeSubpath()
        return path
    }

    /// Squat and square-shouldered, stepping down at the cone. The step is shallow
    /// on purpose — the chisel meets this edge, and a deep step left the nib
    /// standing proud of the body like a separate block.
    private func markerPath(in r: CGRect) -> Path {
        let step = r.height * 0.11
        var path = Path()
        path.move(to: CGPoint(x: r.minX + r.width * 0.05, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - r.width * 0.16, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + step))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - step))
        path.addLine(to: CGPoint(x: r.maxX - r.width * 0.16, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.05, y: r.maxY))
        path.addQuadCurve(
            to: CGPoint(x: r.minX + r.width * 0.05, y: r.minY),
            control: CGPoint(x: r.minX - r.width * 0.03, y: r.midY)
        )
        path.closeSubpath()
        return path
    }

    /// A flat slab — the widest thing in the tray.
    private func highlighterPath(in r: CGRect) -> Path {
        let round = r.height * 0.14
        var path = Path()
        path.move(to: CGPoint(x: r.minX + round, y: r.minY))
        path.addQuadCurve(
            to: CGPoint(x: r.minX + round, y: r.maxY),
            control: CGPoint(x: r.minX - round * 0.5, y: r.midY)
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.08))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.08))
        path.closeSubpath()
        return path
    }
}

// MARK: - Nibs

/// A pointed cone — ballpoints and monoline pens.
struct ConeTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.22))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.22))
        path.closeSubpath()
        return path
    }
}

/// A short cone that runs out into a long thin needle — the fineliner.
struct NeedleTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder = rect.minX + rect.width * 0.44
        let thin = rect.height * 0.16
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: shoulder, y: rect.midY - thin))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - thin * 0.3))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + thin * 0.3))
        path.addLine(to: CGPoint(x: shoulder, y: rect.midY + thin))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The machined collar the needle comes out of.
struct NeedleCollarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let shoulder = rect.minX + rect.width * 0.30
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: shoulder, y: rect.midY - rect.height * 0.19))
        path.addLine(to: CGPoint(x: shoulder, y: rect.midY + rect.height * 0.19))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A split nib — fountain pens. Shoulders that curve out of the section, then a
/// long taper to the point.
struct NibShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.20))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX + rect.width * 0.18, y: rect.minY + rect.height * 0.30)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.20),
            control: CGPoint(x: rect.midX + rect.width * 0.18, y: rect.maxY - rect.height * 0.30)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.20),
            control: CGPoint(x: rect.minX - rect.width * 0.22, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> NibShape {
        NibShape(inset: inset + amount)
    }
}

/// An angled chisel — markers and highlighters.
struct ChiselShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.24))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The sharpened wooden cone of a pencil.
struct WoodTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.30, y: rect.midY - rect.height * 0.11))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.30, y: rect.midY + rect.height * 0.11))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The graphite standing out of the sharpened wood.
struct GraphiteTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - rect.width * 0.32, y: rect.midY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.32, y: rect.midY + rect.height * 0.12))
        path.closeSubpath()
        return path
    }
}

/// A worn conical wax point — the crayon. Blunter than a pencil's, but a CONE:
/// a dome here made the crayon read as a bullet.
struct WaxTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let flat = rect.height * 0.17
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.midY - flat))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.midY + flat),
            control: CGPoint(x: rect.maxX + rect.width * 0.12, y: rect.midY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A soft, bellied bristle head narrowing to a point — the watercolour brush.
struct BrushTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.10))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX + rect.width * 0.1, y: rect.minY - rect.height * 0.14)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.10),
            control: CGPoint(x: rect.midX + rect.width * 0.1, y: rect.maxY + rect.height * 0.14)
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
    /// How pointed the tip is: the preview tapers its ends by the same amount the
    /// pen will, so Tip is a slider you can watch rather than one you have to try.
    let tip: Double

    public init(color: ThemeColor, width: Double, opacity: Double, stability: Int, tip: Double = 0) {
        self.color = color
        self.width = width
        self.opacity = opacity
        self.stability = stability
        self.tip = tip
    }

    /// The width at a point `t` (0…1) along the stroke — mirrors `PenShaper.taper`.
    private func taper(at t: CGFloat) -> CGFloat {
        guard tip > 0 else { return 1 }
        let span = CGFloat(min(0.3, tip * 0.32))
        let distance = min(t, 1 - t)
        guard distance < span, span > 0 else { return 1 }
        let narrowest = CGFloat(1 - tip * 0.85)
        return narrowest + (1 - narrowest) * (distance / span)
    }

    public var body: some View {
        Canvas { context, size in
            let wobble = CGFloat(PenSettings.stabilityRange.upperBound - stability) * 0.7
            let steps = 60
            func point(_ step: Int) -> CGPoint {
                let t = CGFloat(step) / CGFloat(steps)
                let x = 14 + t * (size.width - 28)
                let base = size.height / 2 - sin(t * .pi * 2) * (size.height * 0.28)
                return CGPoint(x: x, y: base + sin(t * 34) * wobble)
            }
            // Segment by segment, because a stroke whose width varies along its
            // length isn't one `Path`.
            for step in 0..<steps {
                let t = (CGFloat(step) + 0.5) / CGFloat(steps)
                var segment = Path()
                segment.move(to: point(step))
                segment.addLine(to: point(step + 1))
                context.stroke(
                    segment,
                    with: .color(color.color.opacity(opacity)),
                    style: StrokeStyle(
                        lineWidth: max(1, width * 1.6 * taper(at: t)),
                        lineCap: .round, lineJoin: .round
                    )
                )
            }
        }
        .frame(height: 92)
        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}
