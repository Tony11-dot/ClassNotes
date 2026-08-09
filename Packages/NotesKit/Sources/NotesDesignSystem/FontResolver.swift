import CoreText
import NotesModels
import SwiftUI
import UIKit

/// Turns a persisted font NAME into a real font — the one place that knows how to
/// get each face on screen.
///
/// It exists because `Font.custom(_:size:)` and `UIFont(name:)` fail SILENTLY.
/// Ask for a face iOS won't hand over by name and you get the system font back
/// with no error, so a page beautified into "Rounded" or "New York" came out in
/// plain San Francisco and the font picker looked broken — the setting was
/// honoured, the lookup simply never resolved.
///
/// Two families need it. Apple's own system faces (SF Rounded, New York) are only
/// reachable through a font DESCRIPTOR with a design, never by PostScript name.
/// The bundled brand face needs `CMFonts.registerIfNeeded()` to have run first.
public enum FontResolver {
    /// A face iOS only exposes as a design of the system font.
    private enum SystemDesign {
        case rounded, serif, monospaced
    }

    private static func systemDesign(for name: String) -> SystemDesign? {
        let lowered = name.lowercased()
        if lowered.hasPrefix("sfrounded") || lowered.contains("systemrounded") { return .rounded }
        if lowered.hasPrefix("newyork") { return .serif }
        if lowered.hasPrefix("sfmono") { return .monospaced }
        return nil
    }

    /// The `UIFont` for a stored name. Never nil: an unresolvable name falls back
    /// to the system face at the right size, which is what would have happened
    /// anyway — only now it's a decision instead of an accident.
    public static func uiFont(named name: String?, size: CGFloat, bold: Bool = false) -> UIFont {
        let weight: UIFont.Weight = bold ? .bold : .regular
        guard let name, !name.isEmpty, name != "system" else {
            return .systemFont(ofSize: size, weight: weight)
        }

        if let design = systemDesign(for: name) {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let uiDesign: UIFontDescriptor.SystemDesign = switch design {
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            }
            guard let descriptor = base.fontDescriptor.withDesign(uiDesign) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }

        // The brand face is registered at runtime; asking before that returns nil.
        CMFonts.registerIfNeeded()
        if let exact = UIFont(name: name, size: size) {
            return bold ? bolded(exact, size: size) : exact
        }
        // A family name (rather than a PostScript name) still resolves this way.
        let byFamily = UIFontDescriptor(fontAttributes: [.family: name])
        let resolved = UIFont(descriptor: byFamily, size: size)
        if resolved.familyName.caseInsensitiveCompare(name) == .orderedSame {
            return bold ? bolded(resolved, size: size) : resolved
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    private static func bolded(_ font: UIFont, size: CGFloat) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// The SwiftUI font for a stored name, resolved through the same rules.
    public static func font(named name: String?, size: CGFloat, bold: Bool = false) -> Font {
        Font(uiFont(named: name, size: size, bold: bold))
    }

    /// Whether this name lands on the face it names rather than quietly falling
    /// back. Used by the font-catalog test so a face that stops resolving is a
    /// failed test, not a page that silently prints in the wrong type.
    public static func resolves(_ name: String) -> Bool {
        if systemDesign(for: name) != nil { return true }
        CMFonts.registerIfNeeded()
        if UIFont(name: name, size: 20) != nil { return true }
        let byFamily = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: name]), size: 20)
        return byFamily.familyName.caseInsensitiveCompare(name) == .orderedSame
    }

    // MARK: - Measurement

    /// How wide one line of `text` actually is in this face at this size.
    ///
    /// Beautification used to estimate this as `characters × size × 0.58`, which is
    /// wrong for every face by a different amount: too narrow and the run wrapped
    /// inside a one-line box and got clipped, too wide and the type sat in a box
    /// far from the writing it replaced. Measuring costs a text layout and removes
    /// the guess entirely.
    public static func measureWidth(_ text: String, name: String?, size: CGFloat, bold: Bool = false) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = uiFont(named: name, size: size, bold: bold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The height of one line in this face — ascent + descent + leading, the box a
    /// single line of type genuinely occupies.
    public static func lineHeight(name: String?, size: CGFloat, bold: Bool = false) -> CGFloat {
        ceil(uiFont(named: name, size: size, bold: bold).lineHeight)
    }
}
