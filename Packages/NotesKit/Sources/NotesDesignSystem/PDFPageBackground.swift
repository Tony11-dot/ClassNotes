import NotesModels
import NotesServices
import QuartzCore
import SwiftUI
import UIKit

/// An imported PDF page drawn live from the PDF itself (D-006), so it stays
/// sharp however far the page is zoomed.
///
/// Pages zoom by being laid out bigger, never by a transform, so this is laid
/// out at the page's real on-screen size and draws at the screen's resolution
/// for that size. It is TILED: only tiles on screen are drawn, on background
/// threads, so a page zoomed to several times the screen costs what is visible
/// and not a bitmap of the whole page. The PNG made at import sits underneath
/// and shows until the tiles land, so the page is never blank.
public struct PDFPageBackground: UIViewRepresentable {
    let url: URL
    let pageIndex: Int
    /// Pixels per screen pixel. 1 where the page zooms by layout (the editor);
    /// more where it zooms by `scaleEffect` (the iPhone zoom view), which
    /// stretches whatever was drawn.
    let detail: CGFloat

    public init(url: URL, pageIndex: Int, detail: CGFloat = 1) {
        self.url = url
        self.pageIndex = pageIndex
        self.detail = detail
    }

    public func makeUIView(context: Context) -> PDFTileView { PDFTileView() }

    public func updateUIView(_ view: PDFTileView, context: Context) {
        view.detail = max(1, detail)
        view.show(url: url, pageIndex: pageIndex)
    }
}

/// Hosts the tiled layer. Never takes a touch: the canvas and the page's
/// elements above it own every gesture.
public final class PDFTileView: UIView {
    private let tiles = PDFTiledLayer()
    private let drawer = PDFTileDrawer()
    var detail: CGFloat = 1 {
        didSet { if detail != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        tiles.delegate = drawer
        tiles.tileSize = CGSize(width: 512, height: 512)
        tiles.levelsOfDetail = 1
        tiles.isOpaque = false
        layer.addSublayer(tiles)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(url: URL, pageIndex: Int) {
        if drawer.set(PDFBackgroundSource(url: url, pageIndex: pageIndex)) {
            tiles.setNeedsDisplay()
        }
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale * detail
        guard tiles.frame != bounds || tiles.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiles.frame = bounds
        tiles.contentsScale = scale
        CATransaction.commit()
        tiles.setNeedsDisplay()
    }
}

/// No cross-fade: a tile that fades in over the PNG reads as the page
/// flickering every time it is zoomed.
final class PDFTiledLayer: CATiledLayer {
    override static func fadeDuration() -> CFTimeInterval { 0 }
}

struct PDFBackgroundSource: Equatable {
    let url: URL
    let pageIndex: Int
}

/// Draws the tiles. A separate object (not the view) because a tiled layer
/// draws on background threads and a view is main-actor only.
final class PDFTileDrawer: NSObject, CALayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var source: PDFBackgroundSource?

    /// Whether the source changed.
    func set(_ new: PDFBackgroundSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard source != new else { return false }
        source = new
        return true
    }

    nonisolated func draw(_ layer: CALayer, in context: CGContext) {
        lock.lock()
        let source = self.source
        lock.unlock()
        guard let source, let page = PDFPageDrawing.page(at: source.url, index: source.pageIndex) else { return }
        // The same white paper the import put behind the page.
        context.setFillColor(UIColor.white.cgColor)
        context.fill(context.boundingBoxOfClipPath)
        PDFPageDrawing.draw(page, in: layer.bounds, context: context)
    }

    /// No implicit animations on the tiled layer either.
    nonisolated func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}
