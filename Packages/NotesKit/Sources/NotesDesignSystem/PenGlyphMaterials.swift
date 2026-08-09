import ClassMateTheme
import SwiftUI

/// What the instruments are MADE of: the shared cylinder light, the barrel
/// material, and the specular streak on top of it.
///
/// Split out of `PenGlyphView` so the view file stays about construction rather
/// than surfacing — the four drawing passes are hard enough to follow without the
/// gradients in between them.
extension PenGlyphView {
    /// One cylindrical light, reused by every barrel.
    static let cylinderShading = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.38), location: 0.05),
            .init(color: .white.opacity(0.14), location: 0.26),
            .init(color: .clear, location: 0.50),
            .init(color: .black.opacity(0.14), location: 0.80),
            // A little bounce light along the very bottom edge stops the barrel
            // reading as a shape fading into the background.
            .init(color: .black.opacity(0.05), location: 1.0)
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// What the barrel is made of. Manufactured bodies stay pale so the ink band
    /// reads against them; wax, wood and translucent bodies carry the colour.
    func material(height: CGFloat) -> LinearGradient {
        let base: Color
        switch profile.material {
        case .plasticPale:
            base = theme.isDark ? theme.surfaceRaised.color : Color(white: 0.97)
        case .plasticInk:
            base = color.color.opacity(theme.isDark ? 0.72 : 0.86)
        case .resin:
            // Deep glossy resin: the ink colour, darkened, so a fountain pen reads
            // as a heavier object than a biro.
            base = color.color.opacity(0.9)
        case .wood:
            base = Color(red: 0.85, green: 0.68, blue: 0.42)
        case .wax:
            base = color.color
        case .translucent:
            base = color.color.opacity(0.3)
        }
        return LinearGradient(
            colors: [base, base.opacity(0.86)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// The specular streak. Matte materials (wood, wax, paper-wrapped) get a
    /// fainter one — a crayon does not shine like a lacquered barrel.
    func gloss(width: CGFloat, height: CGFloat) -> some View {
        let sheen: Double = switch profile.material {
        case .resin, .plasticInk, .translucent: 0.55
        case .plasticPale: 0.42
        case .wood, .wax: 0.18
        }
        return Capsule()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0), .white.opacity(sheen), .white.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: width * 0.7, height: max(0.8, height * 0.12))
            .blur(radius: max(0.4, height * 0.045))
            .offset(x: width * 0.12, y: -height * 0.26)
            .frame(width: width, height: height, alignment: .leading)
    }
}
