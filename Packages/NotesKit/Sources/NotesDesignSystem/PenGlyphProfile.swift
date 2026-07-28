import NotesModels
import SwiftUI

/// How one instrument is drawn. Each shipped pen gets a distinct combination, so
/// no two glyphs in the tray look alike.
public struct PenGlyphProfile: Sendable, Equatable {
    /// The barrel's silhouette and its furniture — the instrument's identity.
    public enum Body: Sendable {
        /// Domed back narrowing into a shoulder — the everyday pen.
        case tapered
        /// Near-parallel and thin.
        case slim
        /// Flat back with a plunger standing behind it.
        case clicker
        /// Heavy, bellied, machined bands.
        case fountain
        /// Faceted wood, cut flat, ferrule and eraser.
        case hex
        /// A fat wax cylinder in a paper sleeve.
        case wax
        /// A handle that tapers BACKWARD into a crimped ferrule.
        case handle
        /// Squat and chunky, with a cap seam.
        case marker
        /// The widest body, translucent, ink level showing.
        case highlighter
    }

    /// What the barrel is made of.
    public enum Material: Sendable {
        case plasticPale, plasticInk, resin, wood, wax, translucent
    }

    public enum Tip: Sendable {
        case ball, needle, nib, chisel, wideChisel, wood, waxStub, bristle
    }

    public let body: Body
    public let material: Material
    public let tip: Tip
    /// How much of the glyph's width the nib takes.
    public let tipFraction: CGFloat
    /// How thick the barrel is relative to the glyph — a fineliner is a sliver, a
    /// highlighter fills the row.
    public let barrelHeightFraction: CGFloat
    /// How tall the nib is relative to the BARREL. A cone tucks inside the body
    /// (< 1); a brush head and a fountain nib stand proud of it (> 1).
    public let tipHeightScale: CGFloat

    /// The profile for a preset. Unknown ids (a future pen, a custom one) fall back
    /// to something sensible for their ink family rather than nothing at all.
    public static func of(_ preset: PenPreset) -> PenGlyphProfile {
        if let known = table[preset.id] { return known }
        return fallback(for: preset)
    }

    private static let table: [String: PenGlyphProfile] = [
        // Slim, domed, a grip and a colour band: the everyday pen.
        "flow": PenGlyphProfile(
            body: .tapered, material: .plasticPale, tip: .ball,
            tipFraction: 0.24, barrelHeightFraction: 0.60, tipHeightScale: 0.6
        ),
        // Clicker at the back, fatter body, ink-coloured plastic.
        "ballpoint": PenGlyphProfile(
            body: .clicker, material: .plasticInk, tip: .ball,
            tipFraction: 0.20, barrelHeightFraction: 0.76, tipHeightScale: 0.55
        ),
        // A sliver of a barrel and a long needle in a metal collar.
        "fineliner": PenGlyphProfile(
            body: .slim, material: .plasticPale, tip: .needle,
            tipFraction: 0.34, barrelHeightFraction: 0.42, tipHeightScale: 0.8
        ),
        // Heavy resin, machined bands, split nib.
        "fountain": PenGlyphProfile(
            body: .fountain, material: .resin, tip: .nib,
            tipFraction: 0.30, barrelHeightFraction: 0.92, tipHeightScale: 1.1
        ),
        // Hexagonal wood, ferrule, pink eraser, graphite point.
        "pencil": PenGlyphProfile(
            body: .hex, material: .wood, tip: .wood,
            tipFraction: 0.24, barrelHeightFraction: 0.70, tipHeightScale: 1.0
        ),
        // Fat wax stub in a paper sleeve.
        "crayon": PenGlyphProfile(
            body: .wax, material: .wax, tip: .waxStub,
            tipFraction: 0.24, barrelHeightFraction: 1, tipHeightScale: 0.94
        ),
        // Backward-tapering handle, crimped ferrule, soft bristles.
        "brush": PenGlyphProfile(
            body: .handle, material: .wood, tip: .bristle,
            tipFraction: 0.36, barrelHeightFraction: 0.54, tipHeightScale: 1.55
        ),
        // Squat marker body with a chisel.
        "marker": PenGlyphProfile(
            body: .marker, material: .plasticInk, tip: .chisel,
            tipFraction: 0.26, barrelHeightFraction: 0.90, tipHeightScale: 0.78
        ),
        // Translucent barrel with the ink level showing, and the widest chisel.
        "highlighter": PenGlyphProfile(
            body: .highlighter, material: .translucent, tip: .wideChisel,
            tipFraction: 0.32, barrelHeightFraction: 1, tipHeightScale: 0.84
        )
    ]

    private static func fallback(for preset: PenPreset) -> PenGlyphProfile {
        switch preset.ink {
        case .fountainPen:
            PenGlyphProfile(body: .fountain, material: .resin, tip: .nib,
                            tipFraction: 0.30, barrelHeightFraction: 0.92, tipHeightScale: 1.1)
        case .marker where preset.isHighlighter:
            PenGlyphProfile(body: .highlighter, material: .translucent, tip: .wideChisel,
                            tipFraction: 0.32, barrelHeightFraction: 1, tipHeightScale: 0.84)
        case .marker:
            PenGlyphProfile(body: .marker, material: .plasticInk, tip: .chisel,
                            tipFraction: 0.26, barrelHeightFraction: 0.90, tipHeightScale: 0.78)
        case .pencil:
            PenGlyphProfile(body: .hex, material: .wood, tip: .wood,
                            tipFraction: 0.24, barrelHeightFraction: 0.70, tipHeightScale: 1.0)
        case .crayon:
            PenGlyphProfile(body: .wax, material: .wax, tip: .waxStub,
                            tipFraction: 0.24, barrelHeightFraction: 1, tipHeightScale: 0.94)
        case .watercolor:
            PenGlyphProfile(body: .handle, material: .wood, tip: .bristle,
                            tipFraction: 0.36, barrelHeightFraction: 0.54, tipHeightScale: 1.55)
        case .pen, .monoline:
            PenGlyphProfile(body: .tapered, material: .plasticPale, tip: .ball,
                            tipFraction: 0.24, barrelHeightFraction: 0.62, tipHeightScale: 0.6)
        }
    }
}
