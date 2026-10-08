import ImageIO
import NotesServices
import PencilKit
import UIKit

/// Page renders for lists of pages — the page manager's thumbnails and the
/// iPhone viewer — made ON DEMAND, at the size they're shown, off the main
/// thread, and held in a cache with a memory ceiling.
///
/// Both screens used to render every page of the notebook the moment they
/// opened, on the main thread, at full page resolution, and keep all of it: a
/// full A4 page at the screen's scale is 8–18 MB of bitmap, so a few hundred
/// pages was gigabytes — the screen froze while it rendered and iOS then killed
/// the app for memory. Now a page is rendered when its cell appears, a cell
/// that scrolls away lets go of its image, and the cache evicts by cost.
public final class PageRenderCache: @unchecked Sendable {
    // NSCache is thread-safe; that is the whole of this type's shared state.
    public static let shared = PageRenderCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    init() {}

    /// The page's ink rendered to fit `pixelWidth`, or nil when there is none.
    ///
    /// Keyed by a fingerprint of the ink bytes, so an edited page renders anew
    /// and an unchanged one is free. Dark paper renders with the dark interface
    /// style, the same way the page's own canvas is told to.
    public func ink(
        _ data: Data, pageSize: CGSize, pixelWidth: CGFloat, darkPaper: Bool
    ) async -> UIImage? {
        guard pageSize.width > 0, pixelWidth > 0 else { return nil }
        let key = "ink|\(Self.fingerprint(data))|\(Int(pixelWidth))|\(darkPaper)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            Perf.measure("Page thumbnail") {
                guard let drawing = try? PKDrawing(data: data) else { return nil }
                let scale = pixelWidth / pageSize.width
                var image: UIImage?
                UITraitCollection(userInterfaceStyle: darkPaper ? .dark : .light).performAsCurrent {
                    image = drawing.image(from: CGRect(origin: .zero, size: pageSize), scale: scale)
                }
                return image
            }
        }.value
        if let rendered { cache.setObject(rendered, forKey: key, cost: Self.cost(of: rendered)) }
        return rendered
    }

    /// An imported page background (a PDF page or a photo), decoded straight
    /// to `maxPixel` with ImageIO instead of decoding the full image first.
    public func background(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        guard maxPixel > 0 else { return nil }
        let key = "bg|\(url.lastPathComponent)|\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return UIImage(cgImage: image)
        }.value
        if let decoded { cache.setObject(decoded, forKey: key, cost: Self.cost(of: decoded)) }
        return decoded
    }

    public func removeAll() {
        cache.removeAllObjects()
    }

    /// Hashes every byte. `Data.hashValue` alone is not enough: an edit that
    /// leaves the first bytes and the length alone must still read as a change.
    static func fingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
