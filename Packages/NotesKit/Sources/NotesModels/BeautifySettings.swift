import CoreGraphics
import Foundation

/// Real-time handwriting beautification settings — the panel behind the pen
/// tray's ✨ button. When enabled, each finished line of handwriting is recognized
/// and replaced, in place, by the same words typeset in `fontID`.
public struct BeautifySettings: Sendable, Equatable, Codable {
    /// Master switch. Off means the pencil just draws.
    public var isEnabled: Bool
    /// The catalog id of the writing font (see `FontLibrary` / `CustomFontStore`).
    public var fontID: String
    /// Draw the typeset text heavier when the handwriting was pressed hard.
    public var dynamicBold: Bool
    /// Recognition language, e.g. `en-US`.
    public var language: String
    /// Normalize every beautified line to `fontSize` / `lineSpacing` instead of
    /// matching the handwriting's own size.
    public var unifySizeAndSpacing: Bool
    /// Unified type size in logical page points.
    public var fontSize: Double
    /// Unified line-height multiple.
    public var lineSpacing: Double
    /// How long the pencil must rest before a line is committed, in seconds.
    /// Short enough to feel immediate, long enough not to cut a word in half.
    public var settleDelay: Double

    public init(
        isEnabled: Bool = false,
        fontID: String = FontLibrary.default.id,
        dynamicBold: Bool = false,
        language: String = BeautifyLanguage.default.code,
        unifySizeAndSpacing: Bool = true,
        fontSize: Double = 23,
        lineSpacing: Double = 1.2,
        settleDelay: Double = 0.7
    ) {
        self.isEnabled = isEnabled
        self.fontID = fontID
        self.dynamicBold = dynamicBold
        self.language = language
        self.unifySizeAndSpacing = unifySizeAndSpacing
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.settleDelay = settleDelay
    }

    public static let fontSizeRange: ClosedRange<Double> = 12...48
    public static let lineSpacingRange: ClosedRange<Double> = 0.9...2.4
    public static let settleRange: ClosedRange<Double> = 0.3...2.0

    /// The type size to typeset a recognized line at, given how tall the
    /// handwriting itself was. With unify off we track the writing; with unify on
    /// we use the fixed size so a page of mixed handwriting comes out even.
    public func typeSize(forInkHeight inkHeight: CGFloat) -> Double {
        guard !unifySizeAndSpacing else { return fontSize }
        // Handwriting's ink box is roughly cap-height + descender; a font's point
        // size is a little larger than that visual height.
        let derived = Double(inkHeight) * 0.92
        return min(max(derived, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }
}

/// Recognition languages offered by the beautification panel. Vision supports far
/// more; these are the ones the app lists (and the set the picker is tested over).
public struct BeautifyLanguage: Identifiable, Sendable, Equatable, Codable {
    public let code: String
    public let displayName: String

    public var id: String { code }

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public static let `default` = BeautifyLanguage(code: "en-US", displayName: "English (United States)")

    public static let all: [BeautifyLanguage] = [
        .default,
        BeautifyLanguage(code: "en-GB", displayName: "English (United Kingdom)"),
        BeautifyLanguage(code: "fr-FR", displayName: "French"),
        BeautifyLanguage(code: "de-DE", displayName: "German"),
        BeautifyLanguage(code: "es-ES", displayName: "Spanish"),
        BeautifyLanguage(code: "it-IT", displayName: "Italian"),
        BeautifyLanguage(code: "pt-BR", displayName: "Portuguese (Brazil)"),
        BeautifyLanguage(code: "ar-SA", displayName: "Arabic"),
        BeautifyLanguage(code: "zh-Hans", displayName: "Chinese (Simplified)"),
        BeautifyLanguage(code: "ja-JP", displayName: "Japanese"),
        BeautifyLanguage(code: "ko-KR", displayName: "Korean"),
        BeautifyLanguage(code: "uk-UA", displayName: "Ukrainian"),
        BeautifyLanguage(code: "ru-RU", displayName: "Russian")
    ]

    public static func named(_ code: String) -> BeautifyLanguage {
        all.first { $0.code == code } ?? .default
    }
}
