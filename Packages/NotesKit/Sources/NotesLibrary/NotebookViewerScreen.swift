import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// Read-only page viewer (iPhone). Renders ink via `PKDrawing.image(from:scale:)`
/// composited over the page template — no `PKCanvasView`, no editing surface.
/// Each page renders when it scrolls into view and lets go when it leaves
/// (`PageRenderLayers`): rendering the whole notebook up front, at full size,
/// is what made a long notebook freeze this screen and then run out of memory.
///
/// Everything on a page still *works* here: pinch any page to zoom into it, play
/// voice notes, open attached files, follow links, and lift a strip of tape to
/// check yourself. It just can't be changed.
public struct NotebookViewerScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.paperTone) private var paperTone

    private let notebook: Notebook
    /// The page to scroll to on open — a search hit, or a bookmark.
    private let openingPage: UUID?
    /// On the iPad, a notebook marked View Only can be made editable right
    /// here. The iPhone only ever views.
    private let allowsEditing: Bool

    @State private var manifest: NotebookManifest?
    @State private var zoomedPage: PageRecord?
    /// A page rendered for the share sheet, made only when Share is chosen.
    @State private var sharedPage: SharedPageImage?

    public init(notebook: Notebook, openingPage: UUID? = nil, allowsEditing: Bool = false) {
        self.notebook = notebook
        self.openingPage = openingPage
        self.allowsEditing = allowsEditing
    }

    public var body: some View {
        Group {
            if let manifest {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(Array(manifest.pages.enumerated()), id: \.element.id) { index, page in
                                pageView(page, label: pageLabel(at: index))
                                    .id(page.id)
                            }
                        }
                        .padding(.vertical, 20)
                        .padding(.horizontal, 12)
                    }
                    .onAppear {
                        // Only once the pages exist — scrolling to an id that
                        // isn't in the list yet is a no-op, and this view starts
                        // out with no manifest at all.
                        guard let openingPage,
                              manifest.pages.contains(where: { $0.id == openingPage })
                        else { return }
                        proxy.scrollTo(openingPage, anchor: .top)
                    }
                }
            } else {
                BrandLoader(size: 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.surface.color)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if allowsEditing {
                // The route above this screen swaps it for the editor the moment
                // the flag clears. The long-press menu in the library was the
                // only way out, and nothing here said so.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        try? services.repository.setViewOnly(false, for: notebook)
                    } label: {
                        Label("Make Editable", systemImage: "pencil")
                    }
                }
            }
        }
        .task { await load() }
        .fullScreenCover(item: $zoomedPage) { page in
            ZoomablePageView(page: page, cover: coverPaper) { size, pixelWidth in
                layers(page, size: size, pixelWidth: pixelWidth)
            }
        }
        .sheet(item: $sharedPage) { shared in
            ShareSheet(items: [shared.image])
        }
    }

    /// Everything above the paper, loaded for as long as it's on screen.
    private func layers(_ page: PageRecord, size: CGSize, pixelWidth: CGFloat? = nil) -> PageRenderLayers {
        let store = services.documentStore
        let notebookID = notebook.id
        let pageID = page.id
        return PageRenderLayers(
            page: page,
            displaySize: size,
            darkPaper: page.paperIsDark(theme: theme),
            inkData: { await store.pageData(notebook: notebookID, page: pageID) },
            backgroundURL: page.backgroundPayloadFilename.map {
                store.mediaURL(notebook: notebookID, filename: $0)
            },
            mediaURL: { store.mediaURL(notebook: notebookID, filename: $0) },
            inkPixelWidth: pixelWidth,
            // Only the zoom view (which asks for extra pixels) draws a PDF page
            // live; a list page is sharp enough from its PNG.
            livePDF: pixelWidth == nil ? nil : page.backgroundPDF.map {
                (store.mediaURL(notebook: notebookID, filename: $0.filename), $0.pageIndex)
            }
        )
    }

    /// The cover is page one of the document but it isn't "page 1" — it's the
    /// cover, and numbering starts after it.
    private func pageLabel(at index: Int) -> String {
        guard let manifest else { return "\(index + 1)" }
        if manifest.pages[index].isCover { return "Cover" }
        return "\(manifest.pages.prefix(index + 1).filter { !$0.isCover }.count)"
    }

    /// The notebook's cover artwork, when it has a cover page.
    private var coverPaper: CoverPaper? {
        notebook.usesCoverPage ? notebook.coverPaper : nil
    }

    private func pageView(_ page: PageRecord, label: String) -> some View {
        GeometryReader { geo in
            ZStack {
                PagePaperView(page: page, cover: coverPaper)
                layers(page, size: geo.size)
            }
        }
        .aspectRatio(PageTemplateView.aspectRatio(of: page.style), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
        .overlay(alignment: .topTrailing) {
            Button {
                zoomedPage = page
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.dsFootnote.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
                    .padding(8)
                    .dsGlass(in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel("Zoom into page \(label)")
        }
        .contextMenu {
            Button { zoomedPage = page } label: {
                Label("Zoom in", systemImage: "plus.magnifyingglass")
            }
            // Rendered when chosen, not as part of every page's menu: a
            // ShareLink needs its picture up front, which rendered a full page
            // on the main thread for each page the list laid out.
            Button {
                Task { await share(page) }
            } label: {
                Label("Share page", systemImage: "square.and.arrow.up")
            }
        }
        .accessibilityLabel("Page \(label)")
    }

    private func load() async {
        guard let loaded = try? await services.documentStore.manifest(for: notebook.id) else {
            manifest = NotebookManifest(pages: [])
            return
        }
        manifest = loaded
    }

    /// Full composite (paper + template + ink) for sharing, rendered when Share
    /// is chosen.
    private func share(_ page: PageRecord) async {
        let store = services.documentStore
        let background: UIImage? = if let filename = page.backgroundPayloadFilename {
            await store.mediaData(notebook: notebook.id, filename: filename).flatMap(UIImage.init(data:))
        } else {
            nil
        }
        var ink: UIImage?
        if let data = await store.pageData(notebook: notebook.id, page: page.id) {
            ink = await PageRenderCache.shared.ink(
                data, pageSize: page.logicalSize,
                pixelWidth: page.logicalSize.width * displayScale,
                darkPaper: page.paperIsDark(theme: theme)
            )
        }
        let composite = ZStack {
            PagePaperView(page: page, cover: coverPaper)
            if let background {
                Image(uiImage: background).resizable().scaledToFit()
            }
            PageContentView(
                elements: page.elements,
                displaySize: page.logicalSize,
                logicalSize: page.logicalSize,
                mediaURL: { services.documentStore.mediaURL(notebook: notebook.id, filename: $0) },
                layer: .belowInk
            )
            if let ink {
                Image(uiImage: ink).resizable().scaledToFit()
            }
            PageContentView(
                elements: page.elements,
                displaySize: page.logicalSize,
                logicalSize: page.logicalSize,
                mediaURL: { services.documentStore.mediaURL(notebook: notebook.id, filename: $0) },
                layer: .aboveInk
            )
        }
        .frame(width: page.logicalSize.width, height: page.logicalSize.height)
        .environment(\.theme, theme)
        .environment(\.paperTone, paperTone)

        let renderer = ImageRenderer(content: composite)
        renderer.scale = displayScale
        if let image = renderer.uiImage {
            sharedPage = SharedPageImage(image: image)
        }
    }
}

private struct SharedPageImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// One page, full screen, pinch and drag to zoom — for reading small handwriting
/// on a phone. Voice notes, files, links and tape stay live at every zoom level.
private struct ZoomablePageView<Layers: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    let page: PageRecord
    let cover: CoverPaper?
    /// The page's content at a display size, with its ink rendered this many
    /// pixels wide — sharper than the list's render, so pinching reads.
    let layers: (CGSize, CGFloat) -> Layers

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        ZStack {
            theme.surface.color.ignoresSafeArea()
            GeometryReader { geo in
                ZStack {
                    PagePaperView(page: page, cover: cover)
                    // Three times the shown width (capped): enough detail for
                    // the pinch, without a full-page bitmap per zoom step.
                    layers(
                        displaySize(in: geo.size),
                        min(displaySize(in: geo.size).width * displayScale * 3, 4096)
                    )
                }
                .frame(width: displaySize(in: geo.size).width, height: displaySize(in: geo.size).height)
                .scaleEffect(zoom)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .gesture(
                    SimultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                zoom = min(max(committedZoom * value.magnification, 1), 6)
                            }
                            .onEnded { _ in
                                committedZoom = zoom
                                if zoom <= 1.01 {
                                    offset = .zero
                                    committedOffset = .zero
                                }
                            },
                        DragGesture()
                            .onChanged { value in
                                guard zoom > 1.01 else { return }
                                offset = CGSize(
                                    width: committedOffset.width + value.translation.width,
                                    height: committedOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in committedOffset = offset }
                    )
                )
                .onTapGesture(count: 2) { toggleZoom() }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.dsHeadline)
                    .foregroundStyle(theme.ink.color)
                    .padding(12)
                    .dsGlass(in: Circle())
            }
            .buttonStyle(.plain)
            .padding(18)
            .accessibilityLabel("Close")
        }
        .animation(.spring(duration: 0.26), value: zoom)
    }

    /// The page laid out to fit the screen at zoom 1.
    private func displaySize(in container: CGSize) -> CGSize {
        let aspect = page.logicalSize.width / max(page.logicalSize.height, 1)
        let byWidth = CGSize(width: container.width, height: container.width / aspect)
        if byWidth.height <= container.height { return byWidth }
        return CGSize(width: container.height * aspect, height: container.height)
    }

    private func toggleZoom() {
        if zoom > 1.01 {
            zoom = 1
            committedZoom = 1
            offset = .zero
            committedOffset = .zero
        } else {
            zoom = 2.5
            committedZoom = 2.5
        }
    }
}
