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
    /// How much of the nominal width the tip actually lays down, 0…1.
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
        tip: Double = 0.6,
        sensitivity: Double = 0.4,
        thickness: Double = 1.2,
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

    /// The width actually handed to PencilKit: nominal thickness scaled by the tip.
    public var effectiveWidth: Double {
        max(0.3, thickness * (0.4 + tip * 1.2))
    }

    /// Clamps every field into range — applied whenever settings are loaded from
    /// disk so a hand-edited or future value can't produce an invalid tool.
    public func normalized(in range: ClosedRange<Double>) -> PenSettings {
        PenSettings(
            stability: min(max(stability, Self.stabilityRange.lowerBound), Self.stabilityRange.upperBound),
            tip: min(max(tip, 0.05), 1),
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
    public static let flow = PenPreset(
        id: "flow", displayName: "Flow Pen", ink: .monoline,
        defaults: PenSettings(stability: 1, tip: 0.6, sensitivity: 0.4, thickness: 1.2, concentration: 1),
        symbolName: "pencil.tip"
    )

    public static let all: [PenPreset] = [
        flow,
        PenPreset(
            id: "ballpoint", displayName: "Ballpoint", ink: .pen,
            defaults: PenSettings(stability: 2, tip: 0.55, sensitivity: 0.55, thickness: 2.4, concentration: 1),
            symbolName: "pencil"
        ),
        PenPreset(
            id: "fineliner", displayName: "Fineliner", ink: .monoline,
            defaults: PenSettings(stability: 3, tip: 0.4, sensitivity: 0.1, thickness: 1.6, concentration: 1),
            symbolName: "pencil.line"
        ),
        PenPreset(
            id: "fountain", displayName: "Fountain Pen", ink: .fountainPen,
            defaults: PenSettings(stability: 2, tip: 0.7, sensitivity: 0.85, thickness: 3.2, concentration: 1),
            symbolName: "pencil.tip.crop.circle"
        ),
        PenPreset(
            id: "pencil", displayName: "Pencil", ink: .pencil,
            defaults: PenSettings(stability: 1, tip: 0.65, sensitivity: 0.7, thickness: 3, concentration: 0.9),
            symbolName: "pencil.and.outline"
        ),
        PenPreset(
            id: "crayon", displayName: "Crayon", ink: .crayon,
            defaults: PenSettings(stability: 1, tip: 0.85, sensitivity: 0.6, thickness: 8, concentration: 0.95),
            symbolName: "paintbrush.pointed"
        ),
        PenPreset(
            id: "brush", displayName: "Brush", ink: .watercolor,
            defaults: PenSettings(stability: 2, tip: 0.9, sensitivity: 0.9, thickness: 12, concentration: 0.75),
            symbolName: "paintbrush"
        ),
        PenPreset(
            id: "marker", displayName: "Marker", ink: .marker,
            defaults: PenSettings(stability: 2, tip: 0.8, sensitivity: 0.3, thickness: 9, concentration: 0.85),
            symbolName: "highlighter"
        ),
        PenPreset(
            id: "highlighter", displayName: "Highlighter", ink: .marker,
            defaults: PenSettings(stability: 3, tip: 1, sensitivity: 0, thickness: 22, concentration: 0.35),
            symbolName: "highlighter", isHighlighter: true
        )
    ]

    public static var `default`: PenPreset { flow }

    public static func preset(id: String) -> PenPreset {
        all.first { $0.id == id } ?? flow
    }
}
