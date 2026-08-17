import Foundation

/// A curated typeface for handwriting beautification (OCR → re-typeset text) and
/// for text elements. Backed by fonts that ship with iOS (no bundling, no
/// licensing) plus the app's bundled brand face. Custom bundled `.ttf`s can be
/// added by appending entries with `isBundled: true` and registering them.
public struct HandwritingFont: Identifiable, Sendable, Equatable, Codable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case handwriting
        case typeset
        case brand
        /// A user-uploaded OTF/TTF, registered at runtime (see `CustomFontStore`).
        case custom
    }

    public let id: String          // stable id (also the persisted value)
    public let displayName: String
    /// The PostScript / family name passed to `UIFont`/`Font.custom`.
    public let fontName: String
    public let category: Category

    public init(id: String, displayName: String, fontName: String, category: Category) {
        self.id = id
        self.displayName = displayName
        self.fontName = fontName
        self.category = category
    }
}

/// The curated font pack offered in the pen's beautification panel and the
/// handwriting→text sheet. Order: brand first, then handwriting faces (the
/// point of "beautification"), then clean typeset faces.
public enum FontLibrary {
    public static let brand = HandwritingFont(
        id: "cabinet", displayName: "Cabinet Grotesk",
        fontName: "CabinetGrotesk-Medium", category: .brand
    )

    /// iOS-bundled handwriting/script faces — present on every device.
    public static let handwriting: [HandwritingFont] = [
        .init(id: "noteworthy", displayName: "Noteworthy", fontName: "Noteworthy-Light", category: .handwriting),
        .init(id: "bradley", displayName: "Bradley Hand", fontName: "BradleyHandITCTT-Bold", category: .handwriting),
        .init(id: "marker", displayName: "Marker Felt", fontName: "MarkerFelt-Thin", category: .handwriting),
        .init(id: "chalkboard", displayName: "Chalkboard", fontName: "ChalkboardSE-Regular", category: .handwriting),
        .init(id: "snell", displayName: "Snell Roundhand", fontName: "SnellRoundhand", category: .handwriting),
        .init(id: "savoye", displayName: "Savoye", fontName: "SavoyeLetPlain", category: .handwriting)
    ]

    /// Clean typeset faces for a neat, printed look.
    public static let typeset: [HandwritingFont] = [
        .init(id: "rounded", displayName: "Rounded", fontName: "SFRounded-Regular", category: .typeset),
        .init(id: "newyork", displayName: "New York", fontName: "NewYork-Regular", category: .typeset),
        .init(id: "georgia", displayName: "Georgia", fontName: "Georgia", category: .typeset),
        .init(id: "menlo", displayName: "Menlo", fontName: "Menlo-Regular", category: .typeset),
        // Resolved by `FontResolver` through the system-design path (its name
        // starts "sfmono"), not by PostScript name — this is a real,
        // selectable face, not a placeholder.
        .init(id: "sfmono", displayName: "SF Mono", fontName: "SFMono-Regular", category: .typeset)
    ]

    /// The full curated pack, in display order.
    public static var all: [HandwritingFont] {
        [brand] + handwriting + typeset
    }

    /// Monospace faces only — code blocks offer just these, not the whole pack.
    public static let monospace: [HandwritingFont] = typeset.filter { $0.id == "menlo" || $0.id == "sfmono" }

    public static var `default`: HandwritingFont { brand }

    public static func font(id: String) -> HandwritingFont {
        all.first { $0.id == id } ?? brand
    }

    /// Resolve a persisted `fontName` back to a catalog entry (falls back to
    /// brand). Accepts either the catalog id or the raw font name.
    public static func byNameOrID(_ value: String?) -> HandwritingFont {
        guard let value else { return brand }
        return all.first { $0.id == value || $0.fontName == value } ?? brand
    }
}
