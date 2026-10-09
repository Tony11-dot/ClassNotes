import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Something dragged in, loaded and ready to place.
public enum DroppedItem: Sendable, Equatable {
    case pdf(Data, name: String)
    case image(Data, name: String, fileExtension: String)
    case link(URL)
    case text(String)
    case file(Data, name: String, fileExtension: String)
}

/// What something dragged into ClassNotes becomes, decided from the types the
/// drag offers and nothing else, so the rule is the same on a page, in the
/// library and in a test.
///
/// A drag usually offers SEVERAL types for one thing: a PDF from Files is a
/// `com.adobe.pdf` and a `public.file-url`; a link from Safari is a
/// `public.url` and the same address as `public.plain-text`; a photo is a
/// `public.jpeg` and often a `public.file-url` as well. The order below is
/// what the user meant in each of those cases. A PDF becomes pages, because a
/// PDF dropped on a notebook is a handout to write on, not an attachment to
/// open elsewhere. An address becomes a link before it becomes words. And a
/// file of any other kind is still kept, as a chip that opens it: dropping
/// something and seeing nothing happen is the failure this exists to avoid.
public enum DropRouting {

    public enum Kind: Equatable, Sendable {
        /// Pages, after the page it landed on (or a new notebook, in the library).
        case pdf
        /// A photo, where it landed.
        case image
        /// A web address, as a link chip.
        case link
        /// Words, as a text box.
        case text
        /// Anything else that is a file, as a chip that opens it.
        case file
    }

    /// The types a page accepts.
    public static let pageTypes: [UTType] = [.pdf, .image, .url, .plainText, .item]

    /// What a drag offering `identifiers` becomes, or nil when it offers
    /// nothing a page can hold.
    public static func kind(for identifiers: [String]) -> Kind? {
        let types = identifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .pdf) }) { return .pdf }
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }) { return .link }
        if types.contains(where: { $0.conforms(to: .plainText) }) { return .text }
        if types.contains(where: { $0.conforms(to: .data) || $0.conforms(to: .fileURL) || $0.conforms(to: .content) }) {
            return .file
        }
        return nil
    }

    /// What a drag onto the LIBRARY becomes: only things that can be a
    /// notebook (a PDF, photos, a file). Words and links are refused there,
    /// and so is a notebook being dragged to a shelf, which travels as its id
    /// in plain text — the library must not swallow that drag on its way.
    public static func libraryKind(for identifiers: [String]) -> Kind? {
        switch kind(for: identifiers) {
        case .pdf: .pdf
        case .image: .image
        case .file: .file
        case .link, .text, nil: nil
        }
    }

    /// The identifier to load for `kind`: the first offered one that is that
    /// kind. Loading by the RIGHT identifier matters — asking a Files drag for
    /// "an image" when its first type is the file URL hands back the path.
    public static func identifier(for kind: Kind, in identifiers: [String]) -> String? {
        identifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            switch kind {
            case .pdf: return type.conforms(to: .pdf)
            case .image: return type.conforms(to: .image)
            case .link: return type.conforms(to: .url) && !type.conforms(to: .fileURL)
            case .text: return type.conforms(to: .plainText)
            case .file: return !type.conforms(to: .fileURL) && (type.conforms(to: .data) || type.conforms(to: .content))
            }
        }
    }

    /// The extension to store a dropped file under: the name's own, else the
    /// type's preferred one, else "bin" (a chip still opens it).
    public static func fileExtension(suggestedName: String?, identifier: String?) -> String {
        if let name = suggestedName {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        return identifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "bin"
    }

    /// A box of `size` centred where the drop landed, kept wholly on the page.
    /// Something dropped half off the edge would be half hidden; something
    /// bigger than the page is shrunk to fit, keeping its shape.
    public static func frame(size: CGSize, centredAt point: CGPoint, on page: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, page.width > 0, page.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let shrink = min(1, page.width / size.width, page.height / size.height)
        let width = size.width * shrink, height = size.height * shrink
        let x = min(max(point.x - width / 2, 0), page.width - width)
        let y = min(max(point.y - height / 2, 0), page.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
