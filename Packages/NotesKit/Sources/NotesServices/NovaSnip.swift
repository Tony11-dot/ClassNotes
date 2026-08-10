import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Preparing a snipped region of a page for NOVA to LOOK at.
///
/// A page renders at 2× into a picture far larger than any vision model reads,
/// and the snip travels on a student's phone connection with every follow-up
/// question about it. Both problems are the same problem: send the smallest
/// picture that is still legible.
public enum NovaSnip {
    /// Longest side of the picture that is actually sent. Comfortably above what
    /// vision models sample, and small enough to carry on a follow-up.
    public static let maximumSide: CGFloat = 1200
    public static let jpegQuality: CGFloat = 0.72

    /// The scale factor to bring `size` under `maximumSide` — never above 1, so a
    /// small snip is never blown up into a blurry one.
    public static func downscale(for size: CGSize, limit: CGFloat = maximumSide) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > limit, longest > 0 else { return 1 }
        return limit / longest
    }

    #if canImport(UIKit)
    /// The snip as JPEG data, resized if it was bigger than a model will read.
    /// `limit` also serves the cover sync, whose thumbnails are smaller still.
    public static func encode(_ image: UIImage, limit: CGFloat = maximumSide) -> Data {
        let factor = downscale(for: image.size, limit: limit)
        guard factor < 1 else { return image.jpegData(compressionQuality: jpegQuality) ?? Data() }
        let target = CGSize(
            width: (image.size.width * factor).rounded(),
            height: (image.size.height * factor).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: jpegQuality) ?? Data()
    }
    #endif
}
