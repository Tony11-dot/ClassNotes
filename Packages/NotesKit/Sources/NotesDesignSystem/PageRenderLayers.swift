import ClassMateTheme
import NotesModels
import SwiftUI

/// Everything on a page above its paper — the imported background, elements
/// under the ink, the ink, elements over it — for screens that SHOW pages
/// rather than edit them (the page manager, the iPhone viewer, its zoom).
///
/// The ink and background are loaded when the view appears, through
/// `PageRenderCache`, at the size they're actually shown, and released when it
/// disappears. That is what lets a notebook of hundreds of pages open in those
/// screens at all: see `PageRenderCache` for what the eager version cost.
public struct PageRenderLayers: View {
    @Environment(\.displayScale) private var displayScale

    let page: PageRecord
    let displaySize: CGSize
    let darkPaper: Bool
    let inkData: @Sendable () async -> Data?
    let backgroundURL: URL?
    let mediaURL: (String) -> URL
    /// Render the ink this many pixels wide instead of the shown size — the
    /// zoom view asks for more so handwriting stays sharp when pinched.
    let inkPixelWidth: CGFloat?

    @State private var ink: UIImage?
    @State private var background: UIImage?

    public init(
        page: PageRecord,
        displaySize: CGSize,
        darkPaper: Bool,
        inkData: @escaping @Sendable () async -> Data?,
        backgroundURL: URL?,
        mediaURL: @escaping (String) -> URL,
        inkPixelWidth: CGFloat? = nil
    ) {
        self.page = page
        self.displaySize = displaySize
        self.darkPaper = darkPaper
        self.inkData = inkData
        self.backgroundURL = backgroundURL
        self.mediaURL = mediaURL
        self.inkPixelWidth = inkPixelWidth
    }

    public var body: some View {
        ZStack {
            if let background {
                Image(uiImage: background).resizable().scaledToFit()
            }
            // Same split as the editor: ink paints over images, files and text;
            // tape stays above the ink.
            PageContentView(
                elements: page.elements, displaySize: displaySize,
                logicalSize: page.logicalSize, mediaURL: mediaURL, layer: .belowInk
            )
            if let ink {
                Image(uiImage: ink).resizable().scaledToFit()
            }
            PageContentView(
                elements: page.elements, displaySize: displaySize,
                logicalSize: page.logicalSize, mediaURL: mediaURL, layer: .aboveInk
            )
        }
        .task(id: LoadKey(page: page.id, width: Int(pixelWidth), dark: darkPaper)) { await load() }
        .onDisappear {
            ink = nil
            background = nil
        }
    }

    private var pixelWidth: CGFloat {
        inkPixelWidth ?? displaySize.width * displayScale
    }

    private struct LoadKey: Hashable {
        let page: UUID
        let width: Int
        let dark: Bool
    }

    private func load() async {
        guard pixelWidth > 0 else { return }
        let width = pixelWidth
        let longest = max(width, width * page.logicalSize.height / max(page.logicalSize.width, 1))
        if let backgroundURL {
            background = await PageRenderCache.shared.background(at: backgroundURL, maxPixel: longest)
        }
        guard !Task.isCancelled, let data = await inkData() else {
            ink = nil
            return
        }
        ink = await PageRenderCache.shared.ink(
            data, pageSize: page.logicalSize, pixelWidth: width, darkPaper: darkPaper
        )
    }
}

public extension PageRecord {
    /// Whether this page's paper is dark enough that ink should render the way
    /// it does on a dark page. Mirrors what the editor tells the page's canvas:
    /// the page's own paper colour wins, and only "auto" follows the theme.
    func paperIsDark(theme: ThemeSpec) -> Bool {
        if let hex = paperColorHex, let color = ThemeColor(hex: hex) {
            return color.relativeLuminance < 0.4
        }
        return theme.isDark
    }
}
