import ClassMateTheme
import NotesAI
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPad notebook editor: scrolling multi-page PencilKit canvas + the draggable
/// tool rail, page manager, media/voice/text tools, ruler and NOVA layered on
/// top. Only `App/Routing` may import this module.
public struct EditorScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    private let notebook: Notebook

    @Environment(\.paperTone) private var paperTone

    @State private var model: NotebookEditorModel
    @State private var toolState = ToolState()
    @State private var tracker = ActiveCanvasTracker()

    @State private var rulerVisible = false
    @State private var explainMode = false
    @State private var showPages = false
    @State private var addingBottom = false
    @State private var addingTop = false
    /// Each page's frame in the editor coordinate space, so the magic pen can
    /// map a circled region back to page-logical coordinates for cropping.
    @State private var pageFrames: [UUID: CGRect] = [:]

    // Insertion sheets/state
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showRecorder = false
    @State private var ocrText: OCRResult?
    @State private var novaConversation: NovaConversation?
    @State private var showNova = false
    @State private var beautifying = false
    @State private var editorNotice: String?
    @State private var pageSettings: PageRecord?
    /// Decoded PDF/image page backgrounds, cached so SwiftUI re-renders don't
    /// re-decode the PNG on every frame.
    @State private var backgroundCache = PageImageCache()

    public init(notebook: Notebook) {
        self.notebook = notebook
        // Model is created against the shared store when the view appears; a
        // throwaway store here is replaced in `.task`.
        self._model = State(initialValue: NotebookEditorModel(
            notebookID: notebook.id,
            store: DocumentStore()
        ))
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            theme.surface.color.ignoresSafeArea()
            pageScroll
            edgeLoader(top: true).opacity(addingTop ? 1 : 0)
            edgeLoader(top: false).opacity(addingBottom ? 1 : 0)

            if model.manifest == nil {
                BrandLoader(size: 56).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if rulerVisible {
                RulerOverlay(isVisible: $rulerVisible).ignoresSafeArea()
            }
            if explainMode {
                MagicPenOverlay(
                    onComplete: { points in handleMagicPen(points) },
                    onCancel: { explainMode = false }
                )
                .zIndex(4)
            }

            // Page manager slides in from the leading edge.
            if showPages {
                PageManagerView(model: model, isVisible: $showPages) { id in
                    model.focusedPageID = id
                }
                .transition(.move(edge: .leading))
                .zIndex(2)
            }

            // The draggable tool rail sits above everything.
            ToolRailView(
                toolState: toolState,
                model: model,
                tracker: tracker,
                rulerVisible: $rulerVisible,
                showPages: $showPages,
                onPhoto: { showPhotoPicker = true },
                onFile: { showFileImporter = true },
                onRecord: { showRecorder = true },
                onBeautify: { Task { await beautifyFocusedPage() } }
            )
            .zIndex(3)
        }
        .coordinateSpace(.named("editor"))
        .overlay(alignment: .top) { noticeBanner }
        .overlay { beautifyingOverlay }
        .animation(.spring(duration: 0.3), value: showPages)
        .animation(.spring(duration: 0.3), value: editorNotice)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            model = NotebookEditorModel(notebookID: notebook.id, store: services.documentStore)
            await model.load()
        }
        .onDisappear {
            services.repository.touch(notebook)
            syncPageImages()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in Task { await handlePickedPhoto(item) } }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            handleImportedFile(result)
        }
        .sheet(isPresented: $showRecorder) {
            VoiceRecorderSheet { url, duration in
                Task { await model.insertVoice(fileURL: url, duration: duration) }
            }
        }
        .sheet(item: $ocrText) { result in
            RecognizedTextSheet(text: result.text) { text, fontName in
                Task {
                    await model.insertText(text, fontName: fontName, colorHex: theme.ink.hexString)
                }
            }
        }
        .sheet(isPresented: $showNova) {
            if let conversation = novaConversation {
                NovaChatView(conversation: conversation)
            }
        }
        .sheet(item: $pageSettings) { page in
            PageSettingsSheet(page: page) { template, margin, paperColorHex in
                Task {
                    await model.updatePageSettings(
                        pageID: page.id, template: template, margin: margin,
                        paperColorHex: paperColorHex, clearPaperColor: paperColorHex == nil
                    )
                }
            }
        }
    }

    // MARK: - Transient notices & progress

    @ViewBuilder
    private var noticeBanner: some View {
        if let editorNotice {
            Text(editorNotice)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(theme.accent.color, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: editorNotice) {
                    try? await Task.sleep(for: .seconds(2.6))
                    self.editorNotice = nil
                }
        }
    }

    @ViewBuilder
    private var beautifyingOverlay: some View {
        if beautifying {
            ZStack {
                theme.ink.withAlpha(0.12).color.ignoresSafeArea()
                VStack(spacing: 12) {
                    BrandLoader(size: 44)
                    Text("Beautifying…").font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.ink.color)
                }
                .padding(24)
                .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            }
            .transition(.opacity)
            .zIndex(6)
        }
    }

    // MARK: - Pages

    private var pageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 32) {
                    ForEach(model.pages) { page in
                        pageView(page).id(page.id)
                    }
                }
                .padding(.vertical, 28)
            }
            .onScrollGeometryChange(for: Overscroll.self) { geo in
                let topRest = -geo.contentInsets.top
                let bottomRest = geo.contentSize.height - geo.containerSize.height + geo.contentInsets.bottom
                return Overscroll(
                    top: topRest - geo.contentOffset.y,
                    bottom: geo.contentOffset.y - bottomRest,
                    scrollable: geo.contentSize.height > geo.containerSize.height
                )
            } action: { _, over in
                handleOverscroll(over, proxy: proxy)
            }
        }
    }

    /// Over-scroll past either end grows the notebook: keep dragging past the
    /// last page (or above the first) and a new page — inheriting that page's
    /// paper + margin — slides in.
    private func handleOverscroll(_ over: Overscroll, proxy: ScrollViewProxy) {
        guard over.scrollable else { return }
        let threshold: CGFloat = 120
        if over.bottom > threshold, !addingBottom {
            addingBottom = true
            Task {
                _ = await model.appendInheritingLast()
                addingBottom = false
            }
        }
        if over.top > threshold, !addingTop {
            addingTop = true
            let anchor = model.pages.first?.id
            Task {
                _ = await model.prependInheritingFirst()
                // Keep the viewport steady: the new page grew above, so pin the
                // page that used to be first back to the top.
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                addingTop = false
            }
        }
    }

    private func edgeLoader(top: Bool) -> some View {
        VStack {
            if !top { Spacer() }
            ZStack {
                Circle().stroke(theme.separator.color, lineWidth: 2).frame(width: 40, height: 40)
                ProgressView().tint(theme.accent.color)
                Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(theme.accent.color)
                    .offset(y: 14)
            }
            .padding(16)
            if top { Spacer() }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private func pageView(_ page: PageRecord) -> some View {
        GeometryReader { geo in
            ZStack {
                PageTemplateView(template: page.template, margin: page.margin, paperColorHex: page.paperColorHex)
                if let bg = backgroundImage(for: page) {
                    Image(uiImage: bg).resizable().scaledToFit()
                }
                CanvasPageView(
                    notebookID: notebook.id,
                    page: page,
                    toolState: toolState,
                    tracker: tracker,
                    onFocus: { model.focusedPageID = $0 }
                )
                PageElementsLayer(
                    pageID: page.id,
                    elements: page.elements,
                    model: model,
                    displaySize: geo.size
                )
            }
            .contentShape(Rectangle())
            .onTapGesture { model.focusedPageID = page.id }
        }
        .aspectRatio(
            PageGeometry.size.width / PageGeometry.size.height,
            contentMode: .fit
        )
        .frame(maxWidth: 840)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    model.focusedPageID == page.id ? theme.accent.color.opacity(0.5) : theme.separator.color,
                    lineWidth: model.focusedPageID == page.id ? 1.5 : 0.5
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        .padding(.horizontal, 40)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("editor"))
        } action: { frame in
            pageFrames[page.id] = frame
        }
    }

    // MARK: - Toolbar (NOVA + editable handwriting→text; drawing tools live in the rail)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                explainMode.toggle()
            } label: {
                Image(systemName: "sparkles")
            }
            .tint(explainMode ? theme.accent.color : theme.ink.color)
            .accessibilityLabel("Ask NOVA about a selection")

            Menu {
                Button { Task { await recognizeHandwriting() } } label: {
                    Label("Handwriting → text", systemImage: "text.viewfinder")
                }
                Button {
                    pageSettings = model.page(model.focusedPageID) ?? model.pages.first
                } label: {
                    Label("Page settings", systemImage: "slider.horizontal.3")
                }
                Button { showFileImporter = true } label: {
                    Label("Import PDF / file", systemImage: "doc.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

}

// MARK: - Actions

extension EditorScreen {
    /// Beautify = transform the handwriting IN PLACE: OCR the page's ink, let
    /// NOVA tidy it into clean prose, drop it where the writing was, then wipe
    /// the ink. Falls back to the raw OCR text if NOVA is unreachable/offline.
    private func beautifyFocusedPage() async {
        // Grab the best live drawing — the focused page if it has ink, otherwise
        // whatever canvas was last drawn on — so Beautify never silently no-ops
        // because the target canvas scrolled offscreen.
        guard let (pageID, drawing) = tracker.bestDrawing(preferring: model.focusedPageID) else {
            editorNotice = "Write something with the pencil first, then tap Beautify."
            return
        }
        beautifying = true
        defer { beautifying = false }
        let raw = await model.recognizedHandwriting(pageID: pageID, drawing: drawing)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            editorNotice = "Couldn't read that handwriting. Try writing a little larger."
            return
        }
        let cleaned = await services.beautifyText(raw) ?? raw
        let origin = tracker.inkBounds(for: pageID)?.origin ?? .zero
        // Honor the selected font — including a user-uploaded OTF/TTF.
        let font = services.fontStore.resolve(id: toolState.beautifyFontID)
            ?? FontLibrary.font(id: toolState.beautifyFontID)
        await model.placeBeautifiedText(
            cleaned, at: origin,
            fontName: font.fontName,
            colorHex: theme.ink.hexString,
            pageID: pageID
        )
        // Replace, don't stack: remove the original handwriting now that its
        // typeset version sits in the same spot.
        tracker.clearDrawing(for: pageID)
    }

    private func handlePickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        await model.insertImage(data, fileExtension: "jpg")
        photoItem = nil
    }

    private func handleImportedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        // A PDF becomes annotatable page backgrounds (draw on it with every tool);
        // anything else drops in as an openable file chip.
        if url.pathExtension.lowercased() == "pdf" {
            Task {
                if await model.importPDF(data) != nil {
                    editorNotice = "PDF imported — draw on it with any tool."
                } else {
                    editorNotice = "Couldn't read that PDF."
                }
            }
        } else {
            Task {
                await model.insertFile(data, displayName: url.lastPathComponent, fileExtension: url.pathExtension)
            }
        }
    }

    private func recognizeHandwriting() async {
        guard let pageID = model.focusedPageID,
              let drawing = tracker.drawing(for: pageID) else { return }
        let text = await model.recognizeText(pageID: pageID, drawing: drawing)
        if !text.isEmpty { ocrText = OCRResult(text: text) }
    }

    /// Magic pen finished: map the scribble to the page under it, crop that
    /// region (text OR image), and hand it to NOVA.
    private func handleMagicPen(_ points: [CGPoint]) {
        explainMode = false
        guard points.count > 1 else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }
        let region = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let center = CGPoint(x: region.midX, y: region.midY)

        // The page under the scribble's center (fallback to the focused page).
        let target = pageFrames.first(where: { $0.value.contains(center) })
            ?? model.focusedPageID.flatMap { id in pageFrames[id].map { (id, $0) } }
        guard let (pageID, frame) = target, frame.width > 1 else { return }

        let scale = frame.width / PageGeometry.size.width
        let onPage = region.intersection(frame)
        guard onPage.width > 8, onPage.height > 8 else { return }
        let logical = CGRect(
            x: (onPage.minX - frame.minX) / scale,
            y: (onPage.minY - frame.minY) / scale,
            width: onPage.width / scale,
            height: onPage.height / scale
        )
        model.focusedPageID = pageID
        Task { await runMagicExplain(pageID: pageID, logicalRegion: logical) }
    }

    @MainActor
    private func runMagicExplain(pageID: UUID, logicalRegion: CGRect) async {
        guard let page = model.page(pageID) else { return }
        let full = renderPageImage(page)
        let cropped = crop(full, to: logicalRegion) ?? full
        let ocr = await model.ocr(image: cropped)
        let jpeg = cropped.jpegData(compressionQuality: 0.7) ?? Data()

        let conversation = services.makeNovaConversation()
        conversation.explainRegion(image: jpeg, ocrHint: ocr)
        novaConversation = conversation
        showNova = true
    }

    /// Renders one page (paper + margin + ink + elements) to an image in the
    /// fixed logical page space, so the magic pen can crop a region from it.
    @MainActor
    private func renderPageImage(_ page: PageRecord, scale: CGFloat = 2) -> UIImage {
        let pageRect = CGRect(origin: .zero, size: PageGeometry.size)
        let ink = tracker.drawing(for: page.id)?.image(from: pageRect, scale: scale)
        let content = ZStack {
            PageTemplateView(template: page.template, margin: page.margin, paperColorHex: page.paperColorHex)
            if let bg = backgroundImage(for: page) { Image(uiImage: bg).resizable().scaledToFit() }
            if let ink { Image(uiImage: ink).resizable().scaledToFit() }
            PageElementsLayer(pageID: page.id, elements: page.elements, model: model, displaySize: PageGeometry.size)
        }
        .frame(width: PageGeometry.size.width, height: PageGeometry.size.height)
        .environment(\.theme, theme)
        .environment(\.paperTone, paperTone)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.uiImage ?? UIImage()
    }

    /// Render every page to a PNG and push it up so the ClassMate ClassNotes tab
    /// shows real content. Best-effort; SyncService no-ops when signed out.
    @MainActor
    private func syncPageImages() {
        let pages = model.pages
        guard !pages.isEmpty else { return }
        let images: [NotebookPageImage] = pages.enumerated().compactMap { index, page in
            guard let data = renderPageImage(page, scale: 1.5).pngData() else { return nil }
            return NotebookPageImage(
                pageIndex: index,
                dataUrl: "data:image/png;base64,\(data.base64EncodedString())"
            )
        }
        services.sync.pushPageImages(notebookID: notebook.id, images: images)
    }

    /// The decoded background image for a page (imported PDF/image), or nil.
    private func backgroundImage(for page: PageRecord) -> UIImage? {
        guard let filename = page.backgroundPayloadFilename else { return nil }
        if let cached = backgroundCache.image(for: filename) { return cached }
        guard let data = try? Data(contentsOf: model.mediaURL(filename: filename)),
              let image = UIImage(data: data) else { return nil }
        backgroundCache.set(image, for: filename)
        return image
    }

    private func crop(_ image: UIImage, to logical: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let pixelsPerPoint = CGFloat(cg.width) / PageGeometry.size.width
        let px = CGRect(
            x: logical.minX * pixelsPerPoint, y: logical.minY * pixelsPerPoint,
            width: logical.width * pixelsPerPoint, height: logical.height * pixelsPerPoint
        )
        guard px.width > 4, px.height > 4, let region = cg.cropping(to: px) else { return nil }
        return UIImage(cgImage: region)
    }
}

/// Over-scroll distances past the top/bottom of the page scroll, used to grow
/// the notebook on demand.
private struct Overscroll: Equatable {
    var top: CGFloat
    var bottom: CGFloat
    var scrollable: Bool
}

/// Identifiable wrapper so recognized text can drive a `.sheet(item:)`.
struct OCRResult: Identifiable {
    let id = UUID()
    let text: String
}

/// Tiny in-memory cache of decoded page-background images, keyed by media
/// filename, so scrolling / re-render doesn't re-decode PDFs every frame.
final class PageImageCache {
    private let cache = NSCache<NSString, UIImage>()
    func image(for filename: String) -> UIImage? { cache.object(forKey: filename as NSString) }
    func set(_ image: UIImage, for filename: String) { cache.setObject(image, forKey: filename as NSString) }
}
