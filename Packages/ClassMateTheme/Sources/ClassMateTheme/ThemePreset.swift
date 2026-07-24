import Foundation

/// The 19 built-in themes, extracted verbatim from ClassMate
/// (`apps/classmate_mobile/lib/core/theme/theme_controller.dart`, resolved
/// through ClassMate's own `appThemeColorScheme()` on 2026-07-24).
///
/// Token mapping from ClassMate's Material 3 scheme:
/// accent ← primary, accentMuted ← primaryContainer, surface ← surface,
/// surfaceRaised ← surfaceContainerHigh, paper ← surfaceContainerLowest,
/// ink ← onSurface, inkSecondary ← onSurfaceVariant, separator ← outlineVariant.
/// glassTint is accent at 20% opacity.
///
/// Values are pinned by `themes.json` + the parity test — never edit by hand.
public enum ThemePreset: String, CaseIterable, Sendable, Codable, Identifiable {
    // Light family
    case light
    case coffee
    case matcha
    case rose
    case sand
    case sky
    case lavender
    case peach
    case mint
    // Dark family
    case dark
    case midnight
    case nord
    case forest
    case dracula
    case obsidian
    case wine
    case solarized
    case plum
    case ocean

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rose: "Rosé"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public var isDark: Bool {
        switch self {
        case .light, .coffee, .matcha, .rose, .sand, .sky, .lavender, .peach, .mint:
            false
        case .dark, .midnight, .nord, .forest, .dracula, .obsidian, .wine, .solarized, .plum, .ocean:
            true
        }
    }

    public static var lightFamily: [ThemePreset] { allCases.filter { !$0.isDark } }
    public static var darkFamily: [ThemePreset] { allCases.filter(\.isDark) }

    /// Opacity applied to the accent to produce the default glass tint.
    public static let glassTintAlpha: Double = 0.2

    public var accent: ThemeColor { Self.tokens[self]!.color(\.accent) }

    public var spec: ThemeSpec {
        let raw = Self.tokens[self]!
        let accent = raw.color(\.accent)
        return ThemeSpec(
            id: rawValue,
            displayName: displayName,
            isDark: isDark,
            accent: accent,
            accentMuted: raw.color(\.accentMuted),
            surface: raw.color(\.surface),
            surfaceRaised: raw.color(\.surfaceRaised),
            paper: raw.color(\.paper),
            ink: raw.color(\.ink),
            inkSecondary: raw.color(\.inkSecondary),
            glassTint: accent.withAlpha(Self.glassTintAlpha),
            separator: raw.color(\.separator),
            coverPalette: Self.coverPalette(leadingWith: self)
        )
    }

    /// The shared cover palette: every preset accent, with `leader`'s first.
    public static func coverPalette(leadingWith leader: ThemePreset) -> [ThemeColor] {
        [leader.accent] + allCases.filter { $0 != leader }.map(\.accent)
    }

    /// Nearest preset to an arbitrary spec by summed per-token color distance.
    /// Used to keep notebooks presentable if custom themes lose entitlement.
    public static func nearest(to spec: ThemeSpec) -> ThemePreset {
        allCases.min { lhs, rhs in
            lhs.spec.distance(to: spec) < rhs.spec.distance(to: spec)
        } ?? .light
    }

    // MARK: - Raw values (generated from the ClassMate dump — do not hand-edit)

    private struct RawTokens {
        let accent: String
        let accentMuted: String
        let surface: String
        let surfaceRaised: String
        let paper: String
        let ink: String
        let inkSecondary: String
        let separator: String

        func color(_ keyPath: KeyPath<RawTokens, String>) -> ThemeColor {
            ThemeColor(hex: self[keyPath: keyPath])!
        }
    }

    private static let tokens: [ThemePreset: RawTokens] = [
        .light: RawTokens(
            accent: "#256489", accentMuted: "#C9E6FF",
            surface: "#F6F9FE", surfaceRaised: "#E5E8ED", paper: "#FFFFFF",
            ink: "#181C20", inkSecondary: "#41474D", separator: "#C1C7CE"
        ),
        .coffee: RawTokens(
            accent: "#88511E", accentMuted: "#F0DAC2",
            surface: "#F3E9D8", surfaceRaised: "#E9DCC7", paper: "#FBF4E7",
            ink: "#3B2F25", inkSecondary: "#6A5B4B", separator: "#CDBBA0"
        ),
        .matcha: RawTokens(
            accent: "#416835", accentMuted: "#DCE9C4",
            surface: "#F1F4E7", surfaceRaised: "#DFE5CC", paper: "#F8FAEF",
            ink: "#2B3327", inkSecondary: "#586353", separator: "#C4CCAF"
        ),
        .rose: RawTokens(
            accent: "#8D4A5D", accentMuted: "#F4DDE3",
            surface: "#FAF4ED", surfaceRaised: "#EADFD4", paper: "#FFFAF3",
            ink: "#575279", inkSecondary: "#797593", separator: "#DDD0C4"
        ),
        .sand: RawTokens(
            accent: "#8C4F26", accentMuted: "#F3DCC4",
            surface: "#F5EDE0", surfaceRaised: "#E4D7C2", paper: "#FCF6EC",
            ink: "#3E342A", inkSecondary: "#6E6152", separator: "#D2C2AB"
        ),
        .sky: RawTokens(
            accent: "#38608F", accentMuted: "#CFE1F3",
            surface: "#EDF3F9", surfaceRaised: "#D6E2ED", paper: "#F6FAFD",
            ink: "#27333E", inkSecondary: "#556472", separator: "#C0CEDC"
        ),
        .lavender: RawTokens(
            accent: "#66558E", accentMuted: "#E4DAF6",
            surface: "#F3EFFA", surfaceRaised: "#DFD8ED", paper: "#FAF7FE",
            ink: "#332C43", inkSecondary: "#635A73", separator: "#CEC4DE"
        ),
        .peach: RawTokens(
            accent: "#904B3F", accentMuted: "#F8D9CE",
            surface: "#FBEEE7", surfaceRaised: "#EBD8CD", paper: "#FFF7F2",
            ink: "#43322C", inkSecondary: "#77605A", separator: "#DCC7BD"
        ),
        .mint: RawTokens(
            accent: "#096B5A", accentMuted: "#CDE8DE",
            surface: "#EAF4EF", surfaceRaised: "#D1E1DA", paper: "#F4FAF7",
            ink: "#26332E", inkSecondary: "#54655E", separator: "#BFD3CB"
        ),
        .dark: RawTokens(
            accent: "#94CDF7", accentMuted: "#004C6E",
            surface: "#101417", surfaceRaised: "#262A2E", paper: "#0A0F12",
            ink: "#DFE3E8", inkSecondary: "#C1C7CE", separator: "#41474D"
        ),
        .midnight: RawTokens(
            accent: "#8FA6FF", accentMuted: "#283A72",
            surface: "#0E1428", surfaceRaised: "#212A48", paper: "#0A0F20",
            ink: "#DCE2F4", inkSecondary: "#9AA6C6", separator: "#2E3A5C"
        ),
        .nord: RawTokens(
            accent: "#88C0D0", accentMuted: "#3B4252",
            surface: "#2E3440", surfaceRaised: "#434C5E", paper: "#272C36",
            ink: "#ECEFF4", inkSecondary: "#C8CFDC", separator: "#434C5E"
        ),
        .forest: RawTokens(
            accent: "#A7C080", accentMuted: "#425047",
            surface: "#2D353B", surfaceRaised: "#3D484D", paper: "#272E33",
            ink: "#D3C6AA", inkSecondary: "#A6B0A0", separator: "#3D484D"
        ),
        .dracula: RawTokens(
            accent: "#BD93F9", accentMuted: "#44415E",
            surface: "#282A36", surfaceRaised: "#3C3F51", paper: "#21222C",
            ink: "#F8F8F2", inkSecondary: "#B8BAC8", separator: "#44475A"
        ),
        .obsidian: RawTokens(
            accent: "#57D6E0", accentMuted: "#14424A",
            surface: "#111315", surfaceRaised: "#23272B", paper: "#0B0C0E",
            ink: "#E4E6E8", inkSecondary: "#9BA1A6", separator: "#2A2F34"
        ),
        .wine: RawTokens(
            accent: "#EC9AAE", accentMuted: "#5C2434",
            surface: "#241016", surfaceRaised: "#3D1F28", paper: "#1C0B10",
            ink: "#F3DDE3", inkSecondary: "#C79AA4", separator: "#4A2C33"
        ),
        .solarized: RawTokens(
            accent: "#C99A2E", accentMuted: "#554614",
            surface: "#002B36", surfaceRaised: "#0E4653", paper: "#00232C",
            ink: "#93A1A1", inkSecondary: "#839496", separator: "#0E4653"
        ),
        .plum: RawTokens(
            accent: "#C9A2ED", accentMuted: "#48335E",
            surface: "#1E1526", surfaceRaised: "#342740", paper: "#17101E",
            ink: "#E9DFF3", inkSecondary: "#B1A3C0", separator: "#362A43"
        ),
        .ocean: RawTokens(
            accent: "#56C7D4", accentMuted: "#1A4B54",
            surface: "#0C1E24", surfaceRaised: "#1D3A43", paper: "#07171C",
            ink: "#DBEBEE", inkSecondary: "#98B0B6", separator: "#23424B"
        )
    ]
}
