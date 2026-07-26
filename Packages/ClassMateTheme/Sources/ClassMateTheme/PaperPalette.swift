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

    /// True when the swatch is a dark stock, so callers can flip ink/line colors
    /// to a light contrast on those pages.
    public static func isDark(_ hex: String?) -> Bool {
        guard let hex, let color = ThemeColor(hex: hex) else { return false }
        // Relative luminance (sRGB approximation).
        let luminance = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
        return luminance < 0.4
    }
}
