import Foundation

/// A curated set of physical-paper colors a page can use, independent of the
/// UI theme: real notebook stocks — bright white, warm creams, manila, soft
/// tints, and dark boards. This is a theme-layer definition, so the raw hex
/// values are allowed to live here (SwiftLint forbids them anywhere else).
public struct PaperSwatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let color: ThemeColor

    public init(id: String, name: String, hex: String) {
        self.id = id
        self.name = name
        self.color = ThemeColor(hex: hex) ?? ThemeColor(red: 1, green: 1, blue: 1)
    }
}

public enum PaperPalette {
    /// Ordered light → warm → tinted → dark, so the picker reads naturally.
    public static let all: [PaperSwatch] = [
        // Whites & neutrals
        PaperSwatch(id: "white",       name: "White",        hex: "#FFFFFF"),
        PaperSwatch(id: "softWhite",   name: "Soft white",   hex: "#F7F7F5"),
        PaperSwatch(id: "paperGray",   name: "Light gray",   hex: "#ECECEE"),
        // Creams / warm stocks
        PaperSwatch(id: "warmWhite",   name: "Warm white",   hex: "#FBF7EF"),
        PaperSwatch(id: "cream",       name: "Cream",        hex: "#F6ECD6"),
        PaperSwatch(id: "manila",      name: "Manila",       hex: "#EFE1BE"),
        PaperSwatch(id: "sand",        name: "Sand",         hex: "#E8D9B5"),
        // Soft tints
        PaperSwatch(id: "blush",       name: "Blush",        hex: "#FBEEF0"),
        PaperSwatch(id: "mint",        name: "Mint",         hex: "#EAF4EC"),
        PaperSwatch(id: "sky",         name: "Sky",          hex: "#EAF1FB"),
        PaperSwatch(id: "lavender",    name: "Lavender",     hex: "#F0ECFA"),
        // Darks / boards
        PaperSwatch(id: "slate",       name: "Slate",        hex: "#33373E"),
        PaperSwatch(id: "charcoal",    name: "Charcoal",     hex: "#1F2124"),
        PaperSwatch(id: "black",       name: "Black",        hex: "#121214"),
        PaperSwatch(id: "chalkboard",  name: "Chalkboard",   hex: "#16241E"),
        PaperSwatch(id: "navy",        name: "Navy",         hex: "#182338"),
    ]

    /// Bright white — the stock a quick note and every imported page uses.
    public static let white = PaperSwatch(id: "white", name: "White", hex: "#FFFFFF")

    /// The default ink/line color offered next to "Auto": true black.
    public static let black = ThemeColor(hex: "#000000") ?? ThemeColor(red: 0, green: 0, blue: 0)

    /// Rule / grid colors offered by the line-color picker, before the theme's own
    /// accent and the custom color wheel. Ordered neutral → classic → bright.
    public static let lineColors: [PaperSwatch] = [
        PaperSwatch(id: "lineBlack",  name: "Black",  hex: "#000000"),
        PaperSwatch(id: "lineGray",   name: "Gray",   hex: "#9A9AA0"),
        PaperSwatch(id: "lineSlate",  name: "Slate",  hex: "#5B6472"),
        PaperSwatch(id: "lineBlue",   name: "Blue",   hex: "#A9CBEE"),
        PaperSwatch(id: "lineNavy",   name: "Navy",   hex: "#31527E"),
        PaperSwatch(id: "lineRed",    name: "Red",    hex: "#D0342C"),
        PaperSwatch(id: "lineGreen",  name: "Green",  hex: "#5A8F63"),
        PaperSwatch(id: "linePurple", name: "Purple", hex: "#9B8CD6"),
        PaperSwatch(id: "lineWhite",  name: "White",  hex: "#FFFFFF")
    ]

    /// Cover colors offered by the notebook cover picker: the ClassMate accents
    /// plus real bookbinding stocks (kraft, khaki, leather, denim) that make the
    /// "simple" covers look like actual notebooks.
    public static let coverStocks: [PaperSwatch] = [
        PaperSwatch(id: "coverKhaki",   name: "Khaki",   hex: "#B5A183"),
        PaperSwatch(id: "coverKraft",   name: "Kraft",   hex: "#C09A6B"),
        PaperSwatch(id: "coverLeather", name: "Leather", hex: "#7A4A32"),
        PaperSwatch(id: "coverDenim",   name: "Denim",   hex: "#4A6484"),
        PaperSwatch(id: "coverSlate",   name: "Slate",   hex: "#4C535C"),
        PaperSwatch(id: "coverIvory",   name: "Ivory",   hex: "#EDE4D3"),
        PaperSwatch(id: "coverBlush",   name: "Blush",   hex: "#E7B7B4"),
        PaperSwatch(id: "coverSage",    name: "Sage",    hex: "#9DB39B"),
        PaperSwatch(id: "coverPlum",    name: "Plum",    hex: "#6C5670"),
        PaperSwatch(id: "coverInk",     name: "Ink",     hex: "#242A33")
    ]

    /// True when the swatch is a dark stock, so callers can flip ink/line colors
    /// to a light contrast on those pages.
    public static func isDark(_ hex: String?) -> Bool {
        guard let hex, let color = ThemeColor(hex: hex) else { return false }
        // Relative luminance (sRGB approximation).
        let luminance = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
        return luminance < 0.4
    }
}
