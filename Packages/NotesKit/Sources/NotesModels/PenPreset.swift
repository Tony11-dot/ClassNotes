import CoreGraphics
import Foundation

/// One writing instrument in the pen tray. The tray shows every preset; the
/// selected one lifts out of the rail, and tapping it again opens its settings.
///
/// `PenPreset` is the *catalog* entry (identity + character); `PenSettings` is the
/// user's tuning of it, which persists per preset.
public struct PenPreset: Identifiable, Sendable, Equatable, Hashable, Codable {
    /// The PencilKit ink family behind the preset. Mirrors `PKInk.InkType` without
    /// making the model layer depend on PencilKit.
    public enum Ink: String, Sendable, Codable, CaseIterable {
        case pen
        case pencil
        case marker
        case fountainPen
        case monoline
        case watercolor
        case crayon
    }

    public let id: String
    public let displayName: String
    public let ink: Ink
    /// Starting tuning — what "Reset" restores.
    public let defaults: PenSettings
    /// The tray glyph. Tray art is drawn procedurally from this + the ink family.
    public let symbolName: String
    /// Highlighter-style pens draw *behind* nothing but read as translucent wash;
    /// the tray sorts them last and the width range is wider.
    public let isHighlighter: Bool

    public init(
        id: String,
        displayName: String,
        ink: Ink,
        defaults: PenSettings,
        symbolName: String,
        isHighlighter: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.ink = ink
        self.defaults = defaults
        self.symbolName = symbolName
        self.isHighlighter = isHighlighter
    }

    /// Thickness slider bounds, in logical page points.
    public var widthRange: ClosedRange<Double> {
        isHighlighter ? 8...48 : 0.4...16
    }
}

/// The user's tuning of one pen. Every field maps to a real effect on the stroke:
/// see `PenShaper`, which rebuilds each finished stroke accordingly.
public struct PenSettings: Sendable, Equatable, Hashable, Codable {
    /// 1 = raw pencil path, 7 = heavily smoothed (the "Stability" slider).
    public var stability: Int
    /// How POINTED the tip is, 0…1 — a pointed tip tapers the stroke in at its
    /// start and end, a blunt one lays full width from the first point to the last.
    ///
    /// It used to be a second multiplier on the width, which meant Tip and
    /// Thickness were one slider wearing two hats: moving either did the same
    /// thing, and their product could exceed the thickness slider's own maximum.
    public var tip: Double
    /// How strongly pressure and speed modulate the width, 0…1.
    public var sensitivity: Double
    /// Nominal stroke width in logical page points.
    public var thickness: Double
    /// Ink opacity, 0…1 (the "Concentration" slider).
    public var concentration: Double
    /// `nil` = follow the theme's ink color.
    public var colorHex: String?

    public init(
        stability: Int = 1,
        tip: Double = 0,
        sensitivity: Double = 0.5,
        thickness: Double = 1.4,
        concentration: Double = 1,
        colorHex: String? = nil
    ) {
        self.stability = stability
        self.tip = tip
        self.sensitivity = sensitivity
        self.thickness = thickness
        self.concentration = concentration
        self.colorHex = colorHex
    }

    public static let stabilityRange = 1...7

    /// The width handed to PencilKit. The Thickness slider IS the width — nothing
    /// else scales it, so the number under your finger is the number on the page.
    public var effectiveWidth: Double {
        max(0.3, thickness)
    }

    /// Whether the tip is pointed enough to taper the stroke at all.
    public var tapersEnds: Bool { tip > 0.02 }

    /// Clamps every field into range — applied whenever settings are loaded from
    /// disk so a hand-edited or future value can't produce an invalid tool.
    public func normalized(in range: ClosedRange<Double>) -> PenSettings {
        PenSettings(
            stability: min(max(stability, Self.stabilityRange.lowerBound), Self.stabilityRange.upperBound),
            tip: min(max(tip, 0), 1),
            sensitivity: min(max(sensitivity, 0), 1),
            thickness: min(max(thickness, range.lowerBound), range.upperBound),
            concentration: min(max(concentration, 0.05), 1),
            colorHex: colorHex
        )
    }
}

/// The pen tray, in tray order (writing pens first, then dry media, then wet
/// media, then the highlighter). Every preset maps to a genuinely different
/// PencilKit ink, so they don't just differ by numbers.
public enum PenLibrary {
    /// Thicknesses are the widths these instruments ALREADY drew at — Tip used to
    /// multiply into the width, so removing that from the arithmetic means folding
    /// the product back into the number, or every pen would suddenly write thinner.
    ///
    /// Flow Pen and Fineliner (formerly first and third in the tray) are gone.
    /// Both were `.monoline` ink, and on real hardware that was the one ink
    /// family that could lose a hold-to-snap shape outright — traced all the
    /// way through this app's own commit code with nothing found (every ink is
    /// treated identically), which means the fault sits in PencilKit's own
    /// renderer for a hand-built `.monoline` stroke. Removing the two presets
    /// removes the only way that ink ever reached the canvas, which is a real
    /// fix, not a workaround — `ShapeSnapper.shapeSafeInk` stays in place as a
    /// second line of defense for a custom or future pen that picks the same
    /// ink family.
    public static let ballpoint = PenPreset(
        id: "ballpoint", displayName: "Ballpoint", ink: .pen,
        // A ball is blunt: a biro's line starts and stops at full width.
        defaults: PenSettings(stability: 2, tip: 0.1, sensitivity: 0.55, thickness: 2.6, concentration: 1),
        symbolName: "pencil"
    )

    public static let all: [PenPreset] = [
        ballpoint,
        PenPreset(
            id: "fountain", displayName: "Fountain Pen", ink: .fountainPen,
            // A nib enters and leaves the paper on its point.
            defaults: PenSettings(stability: 2, tip: 0.7, sensitivity: 0.85, thickness: 4, concentration: 1),
            symbolName: "pencil.tip.crop.circle"
        ),
        PenPreset(
            id: "pencil", displayName: "Pencil", ink: .pencil,
            defaults: PenSettings(stability: 1, tip: 0.4, sensitivity: 0.7, thickness: 3.6, concentration: 0.9),
            symbolName: "pencil.and.outline"
        ),
        PenPreset(
            id: "crayon", displayName: "Crayon", ink: .crayon,
            defaults: PenSettings(stability: 1, tip: 0.15, sensitivity: 0.6, thickness: 11, concentration: 0.95),
            symbolName: "paintbrush.pointed"
        ),
        PenPreset(
            id: "brush", displayName: "Brush", ink: .watercolor,
            // The one instrument whose whole character is the taper.
            defaults: PenSettings(stability: 2, tip: 0.9, sensitivity: 0.9, thickness: 16, concentration: 0.75),
            symbolName: "paintbrush"
        ),
        PenPreset(
            id: "marker", displayName: "Marker", ink: .marker,
            defaults: PenSettings(stability: 2, tip: 0, sensitivity: 0.3, thickness: 12, concentration: 0.85),
            symbolName: "highlighter"
        ),
        PenPreset(
            id: "highlighter", displayName: "Highlighter", ink: .marker,
            // A chisel: dead flat, both ends.
            defaults: PenSettings(stability: 3, tip: 0, sensitivity: 0, thickness: 35, concentration: 0.35),
            symbolName: "highlighter", isHighlighter: true
        )
    ]

    public static var `default`: PenPreset { ballpoint }

    public static func preset(id: String) -> PenPreset {
        all.first { $0.id == id } ?? ballpoint
    }
}
