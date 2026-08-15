import CoreGraphics
import PencilKit
#if canImport(UIKit)
import UIKit
#endif

/// Turns ink into the picture text recognition can actually read.
///
/// `PKDrawing.image(from:scale:)` hands back the ink in its OWN colour on a
/// TRANSPARENT background. Recognition on that is a coin toss: flattening the
/// alpha can put dark ink on a dark field, and on a dark theme the ink is light
/// to begin with, so a pass comes back with nothing at all — which is
/// indistinguishable from "this page has no writing on it".
///
/// Both readers of ink go through here — beautification, which re-typesets one
/// line at a time, and the search indexer, which reads whole pages — so there is
/// one answer to "what does Vision see", not two that can drift apart.
public enum InkRasterizer {
    #if canImport(UIKit)
    /// The region's ink, re-inked solid black on an opaque white page.
    ///
    /// `minimumInkWidth` fattens hairline strokes: a 1-point pen at a small
    /// render scale disappears into the antialiasing.
    public static func recognitionImage(
        of drawing: PKDrawing,
        region: CGRect,
        scale: CGFloat,
        minimumInkWidth: CGFloat = 0
    ) -> UIImage {
        let inked = PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(
                // Always the PEN, whatever wrote it. A marker or a highlighter
                // renders as a wide translucent band whose letters bleed into
                // each other — legible to a person, unreadable to Vision.
                ink: PKInk(.pen, color: .black),
                path: thickened(stroke.path, to: minimumInkWidth),
                transform: stroke.transform,
                mask: stroke.mask
            )
        })
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let size = region.size
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            inked.image(from: region, scale: scale)
                .draw(in: CGRect(origin: .zero, size: size))
        }
    }
    #endif

    /// Widens every point of a stroke path to at least `width`, leaving anything
    /// already thicker alone.
    public static func thickened(_ path: PKStrokePath, to width: CGFloat) -> PKStrokePath {
        guard width > 0 else { return path }
        let points = Array(path)
        guard points.contains(where: { $0.size.width < width || $0.size.height < width })
        else { return path }
        let widened = points.map { point in
            PKStrokePoint(
                location: point.location,
                timeOffset: point.timeOffset,
                size: CGSize(
                    width: max(point.size.width, width),
                    height: max(point.size.height, width)
                ),
                // Faint ink is legible to a person and invisible to Vision, so a
                // stroke being read is drawn at full strength whatever it was
                // written at.
                opacity: max(point.opacity, 1),
                force: point.force,
                azimuth: point.azimuth,
                altitude: point.altitude
            )
        }
        return PKStrokePath(controlPoints: widened, creationDate: path.creationDate)
    }
}
