import CoreGraphics
import NotesModels
import PencilKit
import UIKit

/// The paint-bucket: tap inside a shape and it fills with the current colour.
///
/// The page's ink is vector, but "which region did they tap inside?" has no
/// vector answer — hand-drawn outlines overlap, double back and rarely close
/// cleanly. So the ink is rasterized once, the fill floods out from the tap
/// until it meets ink, and the boundary of what it reached is traced back into a
/// polygon that goes on the page as a `.fill` element.
///
/// The polygon stops where the ink starts, so it can be drawn ABOVE the strokes
/// without hiding them — no separate under-ink layer, and the fill still sits
/// visually beneath the outline that bounds it.
enum FillTool {
    /// Pixels per logical page point in the mask. Fine enough that a fineliner
    /// still reads as a wall the flood can't cross, coarse enough that a full
    /// page is a couple of megapixels rather than twenty.
    static let maskScale: CGFloat = 2

    /// How opaque a pixel has to be before it counts as ink. Antialiased stroke
    /// edges fade to nothing; treating the faintest of them as a wall makes every
    /// fill stop a pixel or two short and leaves a halo.
    static let inkThreshold: UInt8 = 60

    /// Builds the region under `point` and returns its outline in page space, or
    /// nil when the tap was on the ink itself or the fill escaped the shape.
    @MainActor
    static func outline(
        in drawing: PKDrawing, at point: CGPoint, pageSize: CGSize
    ) -> [CGPoint]? {
        guard pageSize.width > 0, pageSize.height > 0,
              CGRect(origin: .zero, size: pageSize).contains(point) else { return nil }
        guard let mask = inkMask(of: drawing, pageSize: pageSize) else { return nil }

        let seed = (
            x: Int(point.x * maskScale),
            y: Int(point.y * maskScale)
        )
        guard let region = FillGeometry.region(in: mask, from: seed) else { return nil }
        let traced = FillGeometry.outline(of: region)
        guard traced.count > 8 else { return nil }
        let path = FillGeometry.path(
            forOutline: traced, maskOrigin: .zero, scale: maskScale
        )
        return path.count > 2 ? path : nil
    }

    /// The page's ink as a boolean raster. Every stroke is drawn opaque black on
    /// white, whatever it was actually drawn with: a highlighter's translucent
    /// wash is a wall to a fill just as much as a biro's line is, and reading the
    /// ink's own alpha would let the flood leak straight through it.
    @MainActor
    static func inkMask(of drawing: PKDrawing, pageSize: CGSize) -> FillGeometry.Mask? {
        let width = Int((pageSize.width * maskScale).rounded())
        let height = Int((pageSize.height * maskScale).rounded())
        guard width > 1, height > 1 else { return nil }

        let opaque = PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(
                ink: PKInk(.pen, color: .black),
                path: stroke.path, transform: stroke.transform, mask: stroke.mask
            )
        })

        var pixels = [UInt8](repeating: 0, count: width * height)
        let space = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let rendered = opaque.image(
            from: CGRect(origin: .zero, size: pageSize), scale: maskScale
        )
        if let cgImage = rendered.cgImage {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        // Dark pixel = ink. The raster is greyscale, so this is one comparison.
        return FillGeometry.Mask(
            width: width, height: height,
            pixels: pixels.map { $0 < 255 - inkThreshold }
        )
    }
}
