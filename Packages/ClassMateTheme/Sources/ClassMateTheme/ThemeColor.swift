import Foundation

/// A platform-independent sRGB color value. The only color currency in the
/// theme system — UI layers convert to SwiftUI `Color` at the edge.
///
/// Encodes to / decodes from a hex string (`#RRGGBB` or `#RRGGBBAA`) so theme
/// JSON stays human-readable and diff-friendly.
public struct ThemeColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
              let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255.0,
                green: Double((value >> 8) & 0xFF) / 255.0,
                blue: Double(value & 0xFF) / 255.0
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255.0,
                green: Double((value >> 16) & 0xFF) / 255.0,
                blue: Double((value >> 8) & 0xFF) / 255.0,
                alpha: Double(value & 0xFF) / 255.0
            )
        }
    }

    /// `#RRGGBB`, with an `AA` suffix only when not fully opaque.
    public var hexString: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        let a = Int((alpha * 255).rounded())
        if a == 255 {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    public func withAlpha(_ newAlpha: Double) -> ThemeColor {
        ThemeColor(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    /// Source-over composite of `self` onto an opaque `background`.
    public func composited(over background: ThemeColor) -> ThemeColor {
        let a = alpha
        return ThemeColor(
            red: red * a + background.red * (1 - a),
            green: green * a + background.green * (1 - a),
            blue: blue * a + background.blue * (1 - a)
        )
    }

    /// WCAG 2.x relative luminance (color treated as opaque).
    public var relativeLuminance: Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// WCAG contrast ratio between two opaque colors, in `1...21`.
    public func contrastRatio(against other: ThemeColor) -> Double {
        let l1 = relativeLuminance
        let l2 = other.relativeLuminance
        let (lighter, darker) = l1 >= l2 ? (l1, l2) : (l2, l1)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Euclidean distance in RGB space (alpha ignored) — used for
    /// nearest-preset fallback.
    public func distance(to other: ThemeColor) -> Double {
        let dr = red - other.red
        let dg = green - other.green
        let db = blue - other.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

extension ThemeColor: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let color = ThemeColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid hex color: \(hex)"
            )
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

extension Double {
    fileprivate var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
