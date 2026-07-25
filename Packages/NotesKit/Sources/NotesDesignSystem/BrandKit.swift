import ClassMateTheme
import CoreText
import SwiftUI

/// The ClassMate brand mark and wordmark, recolored to the active theme's
/// accent exactly like ClassMate's `BrandTint` (single blue source, srcIn).
public struct BrandMark: View {
    @Environment(\.theme) private var theme
    let size: CGFloat
    var tint: Color?

    public init(size: CGFloat = 80, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        Image("BrandMark", bundle: .main)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(tint ?? theme.accent.color)
            .frame(width: size, height: size)
            .accessibilityLabel("ClassMate")
    }
}

public struct BrandWordmark: View {
    @Environment(\.theme) private var theme
    let height: CGFloat
    var tint: Color?

    public init(height: CGFloat = 54, tint: Color? = nil) {
        self.height = height
        self.tint = tint
    }

    public var body: some View {
        Image("BrandWordmark", bundle: .main)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(tint ?? theme.accent.color)
            .frame(height: height)
            .accessibilityLabel("ClassNotes")
    }
}

/// The app's name. Kept in one place so a rename is a one-liner.
public enum BrandName {
    public static let display = "ClassNotes"
}

/// The real ClassNotes lockup — the CN mark + "ClassNotes" wordmark as a single
/// asset — template-tinted to the theme accent, exactly like ClassMate's
/// `ClassMateLogo` (one blue source recoloured `srcIn` → the theme primary).
/// Sized by height; the width follows the artwork's aspect ratio. Used at the
/// top of the login card, mirroring ClassMate's `ClassMateLogo(height: 54)`.
public struct BrandLockup: View {
    @Environment(\.theme) private var theme
    let height: CGFloat
    var tint: Color?

    public init(height: CGFloat = 54, tint: Color? = nil) {
        self.height = height
        self.tint = tint
    }

    public var body: some View {
        Image("BrandLockup", bundle: .main)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(tint ?? theme.accent.color)
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BrandName.display)
    }
}

/// Registers the bundled Cabinet Grotesk faces (ClassMate's default type) so
/// the app can render its wordmark/UI in the same family. Call once at launch.
@MainActor
public enum CMFonts {
    public static let family = "Cabinet Grotesk"
    private static var registered = false

    public static func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        let faces = ["CabinetGrotesk-Regular", "CabinetGrotesk-Medium", "CabinetGrotesk-Bold"]
        for face in faces {
            guard let url = Bundle.module.url(forResource: face, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Cabinet Grotesk at a given size/weight, falling back to the system font
    /// if registration didn't take.
    public static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        registerIfNeeded()
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "CabinetGrotesk-Bold"
        case .medium, .semibold: name = "CabinetGrotesk-Medium"
        default: name = "CabinetGrotesk-Regular"
        }
        return .custom(name, size: size)
    }
}
