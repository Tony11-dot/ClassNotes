import Foundation

/// The complete semantic color recipe for one theme. Everything with color in
/// the app derives from these tokens — no other color source exists.
public struct ThemeSpec: Hashable, Sendable, Codable, Identifiable {
    /// Preset id (`"matcha"`) or `"custom-<uuid>"` for user themes.
    public var id: String
    public var displayName: String
    /// Drives status-bar style, system `ColorScheme` and asset variants.
    public var isDark: Bool

    public var accent: ThemeColor
    public var accentMuted: ThemeColor
    public var surface: ThemeColor
    public var surfaceRaised: ThemeColor
    public var paper: ThemeColor
    public var ink: ThemeColor
    public var inkSecondary: ThemeColor
    /// Feeds `.glassEffect(.regular.tint(...))` — carries its own alpha.
    public var glassTint: ThemeColor
    public var separator: ThemeColor
    /// Notebook cover colors. For presets: all 19 preset accents, reordered so
    /// the active theme's accent leads.
    public var coverPalette: [ThemeColor]

    public init(
        id: String,
        displayName: String,
        isDark: Bool,
        accent: ThemeColor,
        accentMuted: ThemeColor,
        surface: ThemeColor,
        surfaceRaised: ThemeColor,
        paper: ThemeColor,
        ink: ThemeColor,
        inkSecondary: ThemeColor,
        glassTint: ThemeColor,
        separator: ThemeColor,
        coverPalette: [ThemeColor]
    ) {
        self.id = id
        self.displayName = displayName
        self.isDark = isDark
        self.accent = accent
        self.accentMuted = accentMuted
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.paper = paper
        self.ink = ink
        self.inkSecondary = inkSecondary
        self.glassTint = glassTint
        self.separator = separator
        self.coverPalette = coverPalette
    }
}

/// Editable tokens, in the order the theme editor lists them.
public enum ThemeToken: String, CaseIterable, Sendable, Codable, Identifiable {
    case accent
    case accentMuted
    case surface
    case surfaceRaised
    case paper
    case ink
    case inkSecondary
    case glassTint
    case separator

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .accent: "Accent"
        case .accentMuted: "Accent (muted)"
        case .surface: "Surface"
        case .surfaceRaised: "Raised surface"
        case .paper: "Paper"
        case .ink: "Ink"
        case .inkSecondary: "Secondary ink"
        case .glassTint: "Glass tint"
        case .separator: "Separator"
        }
    }
}

extension ThemeSpec {
    public func color(for token: ThemeToken) -> ThemeColor {
        switch token {
        case .accent: accent
        case .accentMuted: accentMuted
        case .surface: surface
        case .surfaceRaised: surfaceRaised
        case .paper: paper
        case .ink: ink
        case .inkSecondary: inkSecondary
        case .glassTint: glassTint
        case .separator: separator
        }
    }

    public mutating func setColor(_ color: ThemeColor, for token: ThemeToken) {
        switch token {
        case .accent: accent = color
        case .accentMuted: accentMuted = color
        case .surface: surface = color
        case .surfaceRaised: surfaceRaised = color
        case .paper: paper = color
        case .ink: ink = color
        case .inkSecondary: inkSecondary = color
        case .glassTint: glassTint = color
        case .separator: separator = color
        }
    }

    /// Per-token color distance to another spec — the basis of the
    /// nearest-preset fallback when custom themes lose their entitlement.
    public func distance(to other: ThemeSpec) -> Double {
        ThemeToken.allCases.reduce(0) { total, token in
            total + color(for: token).distance(to: other.color(for: token))
        }
    }
}
