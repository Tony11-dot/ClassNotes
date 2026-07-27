import ClassMateTheme
import NotesModels
import SwiftUI

/// The painted cover designs: repeating patterns, material textures, and the
/// playful motifs.
///
/// Each is drawn from shades of the cover's own colour, so any design works over
/// any palette entry, and each motif lives in its own small function — adding a
/// design is a self-contained addition, not a change to one big switch.
extension CoverArtView {

    // MARK: - Patterns

    func patternArt(_ context: GraphicsContext, _ size: CGSize) {
        let unit = size.width / 8
        switch design {
        case .stripes: drawStripes(context, size, unit: unit)
        case .pinstripe: drawPinstripe(context, size, unit: unit)
        case .checks: drawChecks(context, size, unit: unit)
        case .dots: drawPatternDots(context, size, unit: unit)
        case .gridlines: drawGridlines(context, size, unit: unit)
        case .diamonds: drawDiamonds(context, size, unit: unit)
        case .arches: drawArches(context, size, unit: unit)
        default: drawWaves(context, size, unit: unit)
        }
    }

    private func drawStripes(_ context: GraphicsContext, _ size: CGSize, unit: CGFloat) {
        var x = -size.height
        while x < size.width + size.height {
            context.stroke(
                segment(CGPoint(x: x, y: 0), CGPoint(x: x + size.height, y: size.height)),
                with: .color(motif), lineWidth: unit * 0.42
            )
            x += unit * 1.2
        }
    }

    private func drawPinstripe(_ context: GraphicsContext, _ size: CGSize, unit: CGFloat) {
        var x = 0.0 as CGFloat
        while x < size.width {
            context.stroke(
                segment(CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)),
                with: .color(motif), lineWidth: 1
            )
            x += unit * 0.5
        }
    }

    private func drawChecks(_ context: GraphicsContext, _ size: CGSize, unit: CGFloat) {
        var row = 0
        var y = 0.0 as CGFloat
        while y < size.height {
            var column = 0
            var x = 0.0 as CGFloat
            while x < size.width {
                if (row + column) % 2 == 0 {
                    context.fill(
                        Path(CGRect(x: x, y: y, width: unit, height: unit)), with: .color(motif)
                    )
                }
                x += unit
                column += 1
            }
            y += unit
            row += 1
        }
    }

    private func drawPatternDots(_ context: GraphicsContext, _ size: CGSize, unit: CGFloat) {
        let spacing = unit * 0.8
        let radius = spacing * 0.16
        var y = spacing / 2
        var row = 0
        while y < size.height {
            var x = spacing / 2 + (row % 2 == 0 ? 0 : spacing / 2)
            while x < size.width {
                context.fill(dot(at: CGPoint(x: x, y: y), radius: radius), with: .color(motifStrong))
                x += spacing
            }
            y += spacing
            row += 1
        }
    }

    private func drawGridlines(_ context: GraphicsContext, _ size: CGSize, unit: CGFloat) {
        let spacing = unit * 0.75
        var x = spacing
        while x < size.width {
            context.stroke(
                segment(CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)),
                with: .color(motif), lineWidth: 0.9
            )
            x += spacing
        }
        var y = spacing
        while y < size.height {
            context.stroke(
                segment(CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)),
                with: .color(motif), lineWidth: 0.9
            )
            y += spacing
        }
    }

    private func drawDiamonds(_ context: GraphicsContext, _ size: CGSize, unit: CGFloat) {
        var y = 0.0 as CGFloat
        var row = 0
        while y < size.height + unit {
            var x = row % 2 == 0 ? 0 : unit / 2
            while x < size.width + unit {
                var path = Path()
                path.move(to: CGPoint(x: x, y: y - unit / 2))
                path.addLine(to: CGPoint(x: x + unit / 2, y: y))
                path.addLine(to: CGPoint(x: x, y: y + unit / 2))
                path.addLine(to: CGPoint(x: x - unit / 2, y: y))
                path.closeSubpath()
                context.stroke(path, with: .color(motif), lineWidth: 1)
                x += unit
            }
            y += unit / 2
            row += 1
        }
    }

    private func drawArches(_ context: GraphicsContext, _ size: CGSize, unit: CGFloat) {
        var y = unit
        while y < size.height + unit * 2 {
            var x = unit
            while x < size.width + unit {
                var path = Path()
                path.addArc(
                    center: CGPoint(x: x, y: y), radius: unit,
                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false
                )
                context.stroke(path, with: .color(motif), lineWidth: 1.4)
                x += unit * 2
            }
            y += unit * 1.6
        }
    }

    private func drawWaves(_ context: GraphicsContext, _ size: CGSize, unit: CGFloat) {
        let amplitude = unit * 0.34
        var y = unit
        while y < size.height + amplitude {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            var x = 0.0 as CGFloat
            while x < size.width {
                let next = x + unit / 2
                path.addQuadCurve(
                    to: CGPoint(x: next, y: y),
                    control: CGPoint(x: x + unit / 4, y: y + amplitude)
                )
                let after = next + unit / 2
                path.addQuadCurve(
                    to: CGPoint(x: after, y: y),
                    control: CGPoint(x: next + unit / 4, y: y - amplitude)
                )
                x = after
            }
            context.stroke(path, with: .color(motif), lineWidth: 1.4)
            y += unit * 0.9
        }
    }

    // MARK: - Gradients

    @ViewBuilder
    func gradientArt(_ size: CGSize) -> some View {
        switch design {
        case .sunrise:
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, glow.opacity(0.5)],
                    startPoint: .center, endPoint: .bottom
                )
                Circle()
                    .fill(glow)
                    .frame(width: size.width * 0.62)
                    .blur(radius: size.width * 0.08)
                    .offset(y: size.height * 0.22)
            }
        case .aurora:
            ZStack {
                Ellipse()
                    .fill(glow.opacity(0.55))
                    .frame(width: size.width * 1.3, height: size.height * 0.42)
                    .rotationEffect(.degrees(-18))
                    .blur(radius: size.width * 0.1)
                    .offset(y: -size.height * 0.16)
                Ellipse()
                    .fill(motifStrong)
                    .frame(width: size.width * 1.1, height: size.height * 0.3)
                    .rotationEffect(.degrees(12))
                    .blur(radius: size.width * 0.11)
                    .offset(y: size.height * 0.2)
            }
        case .halo:
            Circle()
                .strokeBorder(glow, lineWidth: size.width * 0.045)
                .frame(width: size.width * 0.56)
                .blur(radius: 0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        default:
            // dusk — a deep vertical wash with a lifted horizon.
            ZStack {
                LinearGradient(
                    colors: [.black.opacity(0.22), .clear, glow.opacity(0.35)],
                    startPoint: .top, endPoint: .bottom
                )
                Rectangle()
                    .fill(motif)
                    .frame(height: 1.4)
                    .offset(y: size.height * 0.12)
            }
        }
    }

    // MARK: - Textures

    func textureArt(_ context: GraphicsContext, _ size: CGSize) {
        var generator = SeededRandom(seed: design.rawValue.count * 17 + 3)
        switch design {
        case .linen: drawLinen(context, size)
        case .kraft: drawKraft(context, size, &generator)
        case .marble: drawMarble(context, size, &generator)
        default: drawCarbon(context, size)
        }
    }

    private func drawLinen(_ context: GraphicsContext, _ size: CGSize) {
        var y = 0.0 as CGFloat
        while y < size.height {
            context.stroke(
                segment(CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)),
                with: .color(motif.opacity(0.5)), lineWidth: 0.6
            )
            y += 2.4
        }
        var x = 0.0 as CGFloat
        while x < size.width {
            context.stroke(
                segment(CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)),
                with: .color(motif.opacity(0.35)), lineWidth: 0.6
            )
            x += 2.4
        }
    }

    private func drawKraft(
        _ context: GraphicsContext, _ size: CGSize, _ generator: inout SeededRandom
    ) {
        for _ in 0..<700 {
            let x = generator.next() * size.width
            let y = generator.next() * size.height
            let length = 1 + generator.next() * 5
            context.stroke(
                segment(CGPoint(x: x, y: y), CGPoint(x: x + length, y: y + generator.next() * 1.4)),
                with: .color(motif.opacity(0.6)), lineWidth: 0.7
            )
        }
    }

    private func drawMarble(
        _ context: GraphicsContext, _ size: CGSize, _ generator: inout SeededRandom
    ) {
        for vein in 0..<7 {
            var path = Path()
            let startY = size.height * CGFloat(vein) / 7 + generator.next() * 20
            path.move(to: CGPoint(x: -10, y: startY))
            var x = -10.0 as CGFloat
            var y = startY
            while x < size.width + 10 {
                let nextX = x + size.width / 5
                let nextY = y + (generator.next() - 0.5) * size.height * 0.16
                path.addQuadCurve(
                    to: CGPoint(x: nextX, y: nextY),
                    control: CGPoint(x: x + size.width / 10, y: y + (generator.next() - 0.5) * 40)
                )
                x = nextX
                y = nextY
            }
            context.stroke(
                path, with: .color(motif.opacity(0.7)), lineWidth: 1 + generator.next() * 1.6
            )
        }
    }

    /// A fine woven twill.
    private func drawCarbon(_ context: GraphicsContext, _ size: CGSize) {
        let unit = size.width / 26
        var row = 0
        var y = 0.0 as CGFloat
        while y < size.height {
            var column = 0
            var x = 0.0 as CGFloat
            while x < size.width {
                let dark = (row + column) % 2 == 0
                context.fill(
                    Path(
                        roundedRect: CGRect(x: x, y: y, width: unit, height: unit),
                        cornerRadius: unit * 0.2
                    ),
                    with: .color(dark ? motif : glow.opacity(0.1))
                )
                x += unit
                column += 1
            }
            y += unit
            row += 1
        }
    }

    // MARK: - Playful

    func playfulArt(_ context: GraphicsContext, _ size: CGSize) {
        var generator = SeededRandom(seed: design.rawValue.count * 29 + 11)
        switch design {
        case .bloom: drawBloom(context, size, &generator)
        case .stars: drawStars(context, size, &generator)
        case .terrazzo: drawTerrazzo(context, size, &generator)
        default: drawConfetti(context, size, &generator)
        }
    }

    private func drawBloom(
        _ context: GraphicsContext, _ size: CGSize, _ generator: inout SeededRandom
    ) {
        for _ in 0..<16 {
            let center = CGPoint(x: generator.next() * size.width, y: generator.next() * size.height)
            let radius = size.width * (0.04 + generator.next() * 0.05)
            for petal in 0..<5 {
                let angle = Double(petal) / 5 * 2 * .pi
                let petalCenter = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
                context.fill(dot(at: petalCenter, radius: radius * 0.6), with: .color(motif))
            }
        }
    }

    private func drawStars(
        _ context: GraphicsContext, _ size: CGSize, _ generator: inout SeededRandom
    ) {
        for _ in 0..<52 {
            let center = CGPoint(x: generator.next() * size.width, y: generator.next() * size.height)
            let radius = size.width * (0.012 + generator.next() * 0.024)
            context.fill(starPath(center: center, radius: radius), with: .color(motifStrong))
        }
    }

    private func drawTerrazzo(
        _ context: GraphicsContext, _ size: CGSize, _ generator: inout SeededRandom
    ) {
        for _ in 0..<70 {
            let center = CGPoint(x: generator.next() * size.width, y: generator.next() * size.height)
            let width = size.width * (0.02 + generator.next() * 0.05)
            let height = width * (0.6 + generator.next() * 0.8)
            var path = Path(
                roundedRect: CGRect(x: center.x, y: center.y, width: width, height: height),
                cornerRadius: width * 0.35
            )
            path = path.applying(CGAffineTransform(rotationAngle: generator.next() * .pi))
            context.fill(path, with: .color(generator.next() > 0.5 ? motif : motifStrong))
        }
    }

    private func drawConfetti(
        _ context: GraphicsContext, _ size: CGSize, _ generator: inout SeededRandom
    ) {
        for _ in 0..<90 {
            let center = CGPoint(x: generator.next() * size.width, y: generator.next() * size.height)
            let length = size.width * (0.02 + generator.next() * 0.035)
            let angle = generator.next() * 2 * .pi
            context.stroke(
                segment(
                    center,
                    CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
                ),
                with: .color(generator.next() > 0.45 ? motif : motifStrong),
                style: StrokeStyle(lineWidth: size.width * 0.012, lineCap: .round)
            )
        }
    }

    // MARK: - Small shapes

    private func segment(_ from: CGPoint, _ to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }

    private func dot(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
        ))
    }

    /// A five-pointed star, used by the `stars` cover.
    func starPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for point in 0..<10 {
            let angle = Double(point) / 10 * 2 * .pi - .pi / 2
            let pointRadius = point % 2 == 0 ? radius : radius * 0.44
            let position = CGPoint(
                x: center.x + cos(angle) * pointRadius,
                y: center.y + sin(angle) * pointRadius
            )
            if point == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        path.closeSubpath()
        return path
    }
}
