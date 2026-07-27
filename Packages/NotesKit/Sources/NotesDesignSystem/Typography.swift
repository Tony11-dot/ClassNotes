import SwiftUI
import UIKit

/// The app's type scale, in **Cabinet Grotesk** — ClassMate's own family, so the
/// two apps read as one product.
///
/// SwiftUI cannot swap the family behind the built-in text styles globally, so the
/// scale is mirrored here and every call site asks for the `ds` variant instead of
/// the system one. Each entry is built with `relativeTo:`, so Dynamic Type
/// still scales the whole app exactly as the system styles would.
public extension Font {
    static var dsLargeTitle: Font { CMType.style(.largeTitle) }
    static var dsTitle: Font { CMType.style(.title) }
    static var dsTitle2: Font { CMType.style(.title2) }
    static var dsTitle3: Font { CMType.style(.title3) }
    static var dsHeadline: Font { CMType.style(.headline) }
    static var dsSubheadline: Font { CMType.style(.subheadline) }
    static var dsBody: Font { CMType.style(.body) }
    static var dsCallout: Font { CMType.style(.callout) }
    static var dsFootnote: Font { CMType.style(.footnote) }
    static var dsCaption: Font { CMType.style(.caption) }
    static var dsCaption2: Font { CMType.style(.caption2) }

    /// Cabinet Grotesk at an explicit point size — the stand-in for
    /// `.system(size:weight:)`. `design` is accepted and ignored for
    /// drop-in compatibility, EXCEPT `.monospaced`, which keeps the system font
    /// because a proportional face would break aligned figures.
    static func dsSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design? = nil
    ) -> Font {
        if design == .monospaced {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return CMType.font(size: size, weight: weight)
    }
}

/// Resolves the Cabinet Grotesk faces for the type scale.
public enum CMType {
    /// The point size each text style renders at by default (iOS "Large").
    /// `relativeTo:` handles every other Dynamic Type size from here.
    static func size(of style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }

    /// Headlines are semibold in the system scale; everything else is regular.
    static func weight(of style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .largeTitle, .title, .title2, .title3: .bold
        case .headline: .semibold
        default: .regular
        }
    }

    public static func style(_ style: Font.TextStyle) -> Font {
        font(size: size(of: style), weight: weight(of: style), relativeTo: style)
    }

    /// Cabinet Grotesk, falling back to the system font if registration failed —
    /// `Font.custom` with an unregistered name silently renders in the system face,
    /// so a missing resource degrades instead of breaking layout.
    public static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle? = nil
    ) -> Font {
        CMFonts.registerIfNeeded()
        let name = faceName(for: weight)
        if let style {
            return .custom(name, size: size, relativeTo: style)
        }
        return .custom(name, size: size)
    }

    /// Navigation-bar titles are drawn by UIKit, which never sees the SwiftUI
    /// environment font — without this the editor's title bar stayed on the system
    /// face while the rest of the app moved to Cabinet Grotesk. Call once at launch.
    @MainActor
    public static func applyNavigationBarAppearance() {
        CMFonts.registerIfNeeded()
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        if let large = UIFont(name: faceName(for: .bold), size: 34) {
            appearance.largeTitleTextAttributes[.font] = large
        }
        if let inline = UIFont(name: faceName(for: .semibold), size: 17) {
            appearance.titleTextAttributes[.font] = inline
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    /// The three bundled faces cover the weight range; SwiftUI synthesises the
    /// rest from the nearest one.
    static func faceName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "CabinetGrotesk-Bold"
        case .medium, .semibold: "CabinetGrotesk-Medium"
        default: "CabinetGrotesk-Regular"
        }
    }
}
