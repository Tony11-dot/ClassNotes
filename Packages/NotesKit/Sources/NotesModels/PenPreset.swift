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

/// The user's tuning of one pen — deliberately just the two things that don't
/// touch the stroke's own geometry.
///
/// This used to also carry Stability, Tip and Sensitivity, applied by rebuilding
/// every finished stroke's control points (`PenShaper`, removed). That rebuild
/// read PencilKit's OWN fitted spline, whose point count tracks how fast the
/// pencil moved rather than the stroke's length, so the same slider setting
/// barely touched a slow letter and crushed a fast one — round after round of
/// fixing that speed-dependence still left handwriting shrinking or losing
/// edges. Thickness and Concentration were never part of that problem: they set
/// the tool PencilKit draws WITH, not something rewritten after the fact, so
/// they're the only tuning left. What the pencil puts on the page is what gets
/// recorded, full stop.
public struct PenSettings: Sendable, Equatable, Hashable, Codable {
    /// Nominal stroke width in logical page points.
    public var thickness: Double
    /// Ink opacity, 0…1 (the "Concentration" slider).
    public var concentration: Double
    /// `nil` = follow the theme's ink color.
    public var colorHex: String?

    public init(
        thickness: Double = 1.4,
        concentration: Double = 1,
        colorHex: String? = nil
    ) {
        self.thickness = thickness
        self.concentration = concentration
        self.colorHex = colorHex
    }

    /// The width handed to PencilKit. The Thickness slider IS the width — nothing
    /// else scales it, so the number under your finger is the number on the page.
    public var effectiveWidth: Double {
        max(0.3, thickness)
    }

    /// Clamps every field into range — applied whenever settings are loaded from
    /// disk so a hand-edited or future value can't produce an invalid tool.
    public func normalized(in range: ClosedRange<Double>) -> PenSettings {
        PenSettings(
            thickness: min(max(thickness, range.lowerBound), range.upperBound),
            concentration: min(max(concentration, 0.05), 1),
            colorHex: colorHex
        )
    }
}

/// The pen tray: a couple of genuinely different instruments, not a wall of
/// tuning. It used to carry seven presets that mostly differed by exactly the
/// Stability/Tip/Sensitivity tuning `PenSettings` no longer has — once that's
/// gone, having a "Fountain Pen" and a "Pencil" that draw identically apart
/// from width and colour isn't a real choice, it's clutter standing between
/// someone and writing. What's left differs by ink family and use: a general
/// pen, a bold marker, and a translucent highlighter.
///
/// Flow Pen, Fineliner and Brush are also gone for a second reason: all three
/// were (or included) `.monoline`/`.watercolor` ink, and on real hardware
/// `.monoline` was the one ink family that could lose a hold-to-snap shape
/// outright — traced all the way through this app's own commit code with
/// nothing found (every ink is treated identically), which means the fault
/// sits in PencilKit's own renderer for a hand-built stroke in that ink.
/// Removing the preset removes the only way that ink ever reached the canvas.
public enum PenLibrary {
    public static let ballpoint = PenPreset(
        id: "ballpoint", displayName: "Pen", ink: .pen,
        defaults: PenSettings(thickness: 2.6, concentration: 1),
        symbolName: "pencil"
    )

    public static let all: [PenPreset] = [
        ballpoint,
        PenPreset(
            id: "marker", displayName: "Marker", ink: .marker,
            defaults: PenSettings(thickness: 12, concentration: 0.85),
            symbolName: "highlighter"
        ),
        PenPreset(
            id: "highlighter", displayName: "Highlighter", ink: .marker,
            defaults: PenSettings(thickness: 35, concentration: 0.35),
            symbolName: "highlighter", isHighlighter: true
        )
    ]

    public static var `default`: PenPreset { ballpoint }

    public static func preset(id: String) -> PenPreset {
        all.first { $0.id == id } ?? ballpoint
    }
}
