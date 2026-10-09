import CoreGraphics
import Foundation

/// Which page of which PDF a page was imported from (manifest v9, D-006).
///
/// The PDF is stored ONCE in the package's `media/` folder, however many pages
/// came from it; each page names its own page index. Media is shared the way a
/// duplicated page shares its background: removed only when nothing uses it.
public struct PDFBackground: Codable, Sendable, Equatable, Hashable {
    /// The PDF's filename in `media/`.
    public var filename: String
    /// Zero-based page index in that PDF.
    public var pageIndex: Int

    public init(filename: String, pageIndex: Int) {
        self.filename = filename
        self.pageIndex = pageIndex
    }
}

/// Where a PDF page lands on a notebook page: aspect-fit and centred, the way
/// the import has always placed it, with the page's own rotation honoured.
/// One rule for the PNG made at import, the live tiles, the export and the
/// thumbnails, so they line up exactly.
public enum PDFPageFit {
    /// The page's size as it is shown: the media box turned by `rotation`
    /// (PDF `/Rotate`, a multiple of 90, clockwise).
    public static func shownSize(mediaBox: CGRect, rotation: Int) -> CGSize {
        quarterTurns(rotation) % 2 == 0
            ? mediaBox.size
            : CGSize(width: mediaBox.height, height: mediaBox.width)
    }

    /// The rect the page covers inside `target` (top-left origin).
    public static func placement(mediaBox: CGRect, rotation: Int, in target: CGRect) -> CGRect {
        let shown = shownSize(mediaBox: mediaBox, rotation: rotation)
        guard shown.width > 0, shown.height > 0 else { return .zero }
        let scale = min(target.width / shown.width, target.height / shown.height)
        let size = CGSize(width: shown.width * scale, height: shown.height * scale)
        return CGRect(
            x: target.minX + (target.width - size.width) / 2,
            y: target.minY + (target.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// The transform that draws PDF page space (y up, origin at the media
    /// box's corner) into `target` in a TOP-LEFT-origin context (UIKit, a
    /// bitmap set up by UIGraphicsImageRenderer, a PDF page begun by
    /// UIGraphicsPDFRenderer).
    public static func transform(mediaBox: CGRect, rotation: Int, in target: CGRect) -> CGAffineTransform {
        let place = placement(mediaBox: mediaBox, rotation: rotation, in: target)
        let shown = shownSize(mediaBox: mediaBox, rotation: rotation)
        guard shown.width > 0 else { return .identity }
        let scale = place.width / shown.width
        let width = mediaBox.width, height = mediaBox.height
        // 1. Media box corner to the origin.
        var t = CGAffineTransform(translationX: -mediaBox.minX, y: -mediaBox.minY)
        // 2. Turn the page as it is shown, still y-up, back into the positive
        //    quadrant.
        switch quarterTurns(rotation) {
        case 1: t = t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width))
        case 2: t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height))
        case 3: t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0))
        default: break
        }
        // 3. Flip y-up into the top-left context, scale, and place.
        return t
            .concatenating(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: shown.height * scale))
            .concatenating(CGAffineTransform(translationX: place.minX, y: place.minY))
    }

    static func quarterTurns(_ rotation: Int) -> Int {
        ((rotation / 90) % 4 + 4) % 4
    }
}
