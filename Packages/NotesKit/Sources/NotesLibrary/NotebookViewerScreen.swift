import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import SwiftUI

/// Read-only page viewer (iPhone). Renders ink via `PKDrawing.image(from:scale:)`
/// composited over the page template — no `PKCanvasView`, no editing surface.
public struct NotebookViewerScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.paperTone) private var paperTone

    private let notebook: Notebook

    @State private var manifest: NotebookManifest?
    @State private var inkImages: [UUID: UIImage] = [:]

    public init(notebook: Notebook) {
        self.notebook = notebook
    }

    public var body: some View {
        Group {
            if let manifest {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(Array(manifest.pages.enumerated()), id: \.element.id) { index, page in
                            pageView(page, number: index + 1)
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
    }

    private func pageView(_ page: PageRecord, number: Int) -> some View {
        ZStack {
            PageTemplateView(template: page.template)
            if let image = inkImages[page.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(
            PageGeometry.size.width / PageGeometry.size.height,
            contentMode: .fit
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
        .contextMenu {
            ShareLink(
                item: exportImage(page, number: number),
                preview: SharePreview(
                    "\(notebook.title) — page \(number)",
                    image: exportImage(page, number: number)
                )
            ) {
                Label("Share page", systemImage: "square.and.arrow.up")
            }
        }
        .accessibilityLabel("Page \(number)")
    }

    private func load() async {
        guard let loaded = try? await services.documentStore.manifest(for: notebook.id) else {
            manifest = NotebookManifest(pages: [])
            return
        }
        manifest = loaded
        for page in loaded.pages {
            guard let data = await services.documentStore.pageData(
                notebook: notebook.id,
                page: page.id
            ), let drawing = try? PKDrawing(data: data) else { continue }
            let bounds = CGRect(origin: .zero, size: PageGeometry.size)
            inkImages[page.id] = drawing.image(from: bounds, scale: displayScale)
        }
    }

    /// Full composite (paper + template + ink) for sharing.
    private func exportImage(_ page: PageRecord, number: Int) -> Image {
        let composite = ZStack {
            PageTemplateView(template: page.template)
            if let image = inkImages[page.id] {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }
        .frame(width: PageGeometry.size.width, height: PageGeometry.size.height)
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
