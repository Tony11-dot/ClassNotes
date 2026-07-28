import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import SwiftUI

/// Read-only page viewer (iPhone). Renders ink via `PKDrawing.image(from:scale:)`
/// composited over the page template — no `PKCanvasView`, no editing surface.
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

    @State private var manifest: NotebookManifest?
    @State private var inkImages: [UUID: UIImage] = [:]
    @State private var backgrounds: [UUID: UIImage] = [:]
    @State private var zoomedPage: PageRecord?

    public init(notebook: Notebook) {
        self.notebook = notebook
    }

    public var body: some View {
        Group {
            if let manifest {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(Array(manifest.pages.enumerated()), id: \.element.id) { index, page in
                            pageView(page, label: pageLabel(at: index))
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 12)
                }
            } else {
                BrandLoader(size: 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.surface.color)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $zoomedPage) { page in
            ZoomablePageView(
                page: page,
                cover: coverPaper,
                ink: inkImages[page.id],
                background: backgrounds[page.id],
                mediaURL: { services.documentStore.mediaURL(notebook: notebook.id, filename: $0) }
            )
        }
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
                if let background = backgrounds[page.id] {
                    Image(uiImage: background).resizable().scaledToFit()
                }
                if let image = inkImages[page.id] {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                PageContentView(
                    elements: page.elements,
                    displaySize: geo.size,
                    logicalSize: page.logicalSize,
                    mediaURL: { services.documentStore.mediaURL(notebook: notebook.id, filename: $0) }
                )
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
            ShareLink(
                item: exportImage(page),
                preview: SharePreview(
                    "\(notebook.title) — \(label)",
                    image: exportImage(page)
                )
            ) {
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
        for page in loaded.pages {
            if let filename = page.backgroundPayloadFilename,
               let data = await services.documentStore.mediaData(
                   notebook: notebook.id, filename: filename
               ),
               let image = UIImage(data: data) {
                backgrounds[page.id] = image
            }
            guard let data = await services.documentStore.pageData(
                notebook: notebook.id,
                page: page.id
            ), let drawing = try? PKDrawing(data: data) else { continue }
            let bounds = CGRect(origin: .zero, size: page.logicalSize)
            inkImages[page.id] = drawing.image(from: bounds, scale: displayScale)
        }
    }

    /// Full composite (paper + template + ink) for sharing.
    private func exportImage(_ page: PageRecord) -> Image {
        let composite = ZStack {
            PagePaperView(page: page, cover: coverPaper)
            if let background = backgrounds[page.id] {
                Image(uiImage: background).resizable().scaledToFit()
            }
            if let image = inkImages[page.id] {
                Image(uiImage: image).resizable().scaledToFit()
            }
            PageContentView(
                elements: page.elements,
                displaySize: page.logicalSize,
                logicalSize: page.logicalSize,
                mediaURL: { services.documentStore.mediaURL(notebook: notebook.id, filename: $0) }
            )
        }
        .frame(width: page.logicalSize.width, height: page.logicalSize.height)
        .environment(\.theme, theme)
        .environment(\.paperTone, paperTone)

        let renderer = ImageRenderer(content: composite)
        renderer.scale = displayScale
        if let uiImage = renderer.uiImage {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "doc")
    }
}

/// One page, full screen, pinch and drag to zoom — for reading small handwriting
/// on a phone. Voice notes, files, links and tape stay live at every zoom level.
private struct ZoomablePageView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let page: PageRecord
    let cover: CoverPaper?
    let ink: UIImage?
    let background: UIImage?
    let mediaURL: (String) -> URL

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
                    if let background {
                        Image(uiImage: background).resizable().scaledToFit()
                    }
                    if let ink {
                        Image(uiImage: ink).resizable().scaledToFit()
                    }
                    PageContentView(
                        elements: page.elements,
                        displaySize: displaySize(in: geo.size),
                        logicalSize: page.logicalSize,
                        mediaURL: mediaURL
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
