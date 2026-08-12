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

/// iPad notebook editor: a scrolling multi-page PencilKit canvas (or one pannable
/// board), with the draggable tool rail, page manager, tape and text layers, the
/// ruler, and NOVA's saved-chat sidebar on top.
///
/// Only `App/Routing` may import this module.
public struct EditorScreen: View {
    @Environment(AppServices.self) var services
    @Environment(\.theme) var theme

    let notebook: Notebook

    @Environment(\.paperTone) var paperTone

    @State var model: NotebookEditorModel
    @State var toolState = ToolState()
    @State var tracker = ActiveCanvasTracker()
    @State var beautifier = LiveBeautifier()

    @State var rulerVisible = false
    @State var explainMode = false
    @State var showPages = false
    @State var addingBottom = false
    @State var addingTop = false
    /// Each page's frame in the editor coordinate space, so the magic pen can
    /// map a circled region back to page-logical coordinates for cropping.
    @State var pageFrames: [UUID: CGRect] = [:]
    /// Pinch zoom over the page stack, and the value it started the pinch at.
    @State var pageZoom: CGFloat = 1
    @State var zoomAnchor: CGFloat = 1
    /// What the lasso is currently holding, and on which page.
    @State var lassoSelection: PageSelection?
    /// Bumped when something outside the rail asks for the current pen's panel —
    /// a Pencil squeeze mapped to "show colours". A fresh id each time, so asking
    /// twice in a row still opens it the second time.
    @State var penPanelRequest: UUID?

    // Insertion sheets/state
    @State var photoItem: PhotosPickerItem?
    @State var showPhotoPicker = false
    @State var showFileImporter = false
    @State var showRecorder = false
    @State var showScanner = false
    @State var ocrText: OCRResult?
    @State var novaConversation: NovaConversation?
    @State var showNova = false
    @State var editingTextID: UUID?
    @State var beautifying = false
    @State var editorNotice: String?
    @State var pageSettings: PageRecord?
    /// Decoded PDF/image page backgrounds, cached so SwiftUI re-renders don't
    /// re-decode the PNG on every frame.
    @State var backgroundCache = PageImageCache()

    public init(notebook: Notebook) {
        self.notebook = notebook
        // Model is created against the shared store when the view appears; a
        // throwaway store here is replaced in `.task`.
        self._model = State(initialValue: NotebookEditorModel(
            notebookID: notebook.id,
            store: DocumentStore()
        ))
    }

    /// A board is one page you pan and zoom; a notebook scrolls page by page.
    var isBoard: Bool { notebook.kind.isSinglePage }

    public var body: some View {
        // Focus mode is its own screen: one page, an Exit button, nothing else.
        if toolState.focusMode {
            focusSurface
                .navigationTitle(notebook.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .statusBarHidden()
                .onDisappear { syncPageContent() }
        } else {
            editorSurface
        }
    }

    private var editorSurface: some View {
        ZStack(alignment: .leading) {
            theme.surface.color.ignoresSafeArea()
            if isBoard {
                boardSurface
            } else {
                pageScroll
                edgeLoader(top: true).opacity(addingTop ? 1 : 0)
                edgeLoader(top: false).opacity(addingBottom ? 1 : 0)
            }

            if model.manifest == nil {
                BrandLoader(size: 56).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if rulerVisible {
                RulerOverlay(isVisible: $rulerVisible).ignoresSafeArea()
            }
            if explainMode {
                SnipOverlay(
                    onComplete: { rect in handleSnip(rect) },
                    onCancel: { explainMode = false }
                )
                .zIndex(4)
            }

            // Page manager slides in from the leading edge.
            if showPages, !isBoard {
                PageManagerView(
                    model: model,
                    cover: notebook.usesCoverPage ? notebook.coverPaper : nil,
                    isVisible: $showPages
                ) { id in
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
                onBeautifyNow: { Task { await beautifyFocusedPage() } },
                onNova: { openNova() },
                onTapeVisibility: { hidden in
                    Task { await model.setAllTape(hidden: hidden, on: model.focusedPageID) }
                },
                openPenPanel: penPanelRequest
            )
            .zIndex(3)
        }
        .coordinateSpace(.named("editor"))
        .overlay(alignment: .bottomTrailing) { novaBubble }
        .overlay { novaDismissScrim }
        .overlay(alignment: .trailing) { novaPanel }
        .overlay(alignment: .top) { noticeBanner }
        .overlay(alignment: .top) { liveBeautifyIndicator }
        .overlay(alignment: .bottom) { zoomIndicator }
        .overlay { beautifyingOverlay }
        .animation(.spring(duration: 0.3), value: showPages)
        .animation(.spring(duration: 0.3), value: showNova)
        .animation(.spring(duration: 0.3), value: editorNotice)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            // The tools read and write the SAVED settings from here on, so every
            // slider the user moves outlives the editor and reaches their other
            // devices. Pencil gestures the tools can't carry out alone come back
            // through `onPencilOutcome`.
            toolState.bind(to: services.settings)
            toolState.onPencilOutcome = { outcome in
                switch outcome {
                case .handled: break
                case .showColors: penPanelRequest = UUID()
                case .toggleRuler: rulerVisible.toggle()
                case .undo: tracker.undo()
                case .askNova: openNova()
                }
            }
            model = NotebookEditorModel(notebookID: notebook.id, store: services.documentStore)
            // A notebook that should have a cover page gets one here if it was
            // made before covers were pages — once, then never again.
            await model.load(coverStyle: notebook.usesCoverPage ? notebook.pageStyle : nil)
        }
        .onDisappear {
            beautifier.reset()
            // Settle any tuning the user was still adjusting: leaving the editor
            // is exactly when the debounce would otherwise be cancelled.
            services.settings.flush()
            // The cover render has to be written BEFORE the row is touched: the
            // library reloads its thumbnail off `updatedAt`, and `touch` is also
            // what pushes the new cover up to ClassMate.
            Task { @MainActor in
                await saveCoverRender()
                services.repository.touch(notebook)
            }
            syncPageContent()
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
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { images in
                Task {
                    if await model.importImages(images) != nil {
                        editorNotice = "Scan added — annotate it with any tool."
                    }
                }
            }
        }
        .sheet(item: $ocrText) { result in
            RecognizedTextSheet(text: result.text) { text, fontName in
                Task {
                    await model.insertText(text, fontName: fontName, colorHex: theme.ink.hexString)
                }
            }
        }
        .sheet(item: $pageSettings) { page in
            PageSettingsSheet(page: page) { style in
                Task { await model.updatePageSettings(pageID: page.id, style: style) }
            }
        }
    }

    // MARK: - NOVA

    @ViewBuilder
    var novaBubble: some View {
        if !showNova {
            NovaBubble(isActive: novaConversation?.streaming ?? false) { openNova() }
                .padding(.trailing, 26)
                .padding(.bottom, 30)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    var novaPanel: some View {
        if showNova, let conversation = novaConversation {
            NovaSidebar(
                conversation: conversation,
                store: services.novaChats,
                notebookID: notebook.id,
                onClose: { showNova = false }
            )
            .transition(.move(edge: .trailing))
            .zIndex(5)
        }
    }

    /// Anywhere outside the NOVA panel closes it — the page is right there, and
    /// reaching for the small ✕ to get back to it is a tax on every question.
    /// Invisible, so the page stays fully visible while NOVA is open, and only
    /// present while it is.
    @ViewBuilder
    var novaDismissScrim: some View {
        if showNova {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { showNova = false }
                .zIndex(4.5)
        }
    }

    func openNova() {
        if novaConversation == nil {
            novaConversation = services.makeNovaConversation()
        }
        showNova = true
    }

    // MARK: - Transient notices & progress

    @ViewBuilder
    var noticeBanner: some View {
        if let editorNotice {
            Text(editorNotice)
                .font(.dsSubheadline.weight(.medium))
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

    /// What the live pass is doing, in one hairline pill.
    ///
    /// The real-time pass is silent by design — but silence is indistinguishable
    /// from "the switch does nothing", which is how it read when a pass was being
    /// dropped. Reading is now visible, and so is a pass that came back empty.
    @ViewBuilder
    var liveBeautifyIndicator: some View {
        if toolState.beautify.isEnabled, !beautifying {
            Group {
                if beautifier.isWorking {
                    beautifyPill("Reading your writing…", systemImage: "sparkles")
                } else if beautifier.lastPassFoundNothing {
                    beautifyPill(
                        "Couldn't read that — try writing a little larger",
                        systemImage: "questionmark.circle"
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: beautifier.isWorking)
            .animation(.easeInOut(duration: 0.2), value: beautifier.lastPassFoundNothing)
            .allowsHitTesting(false)
        }
    }

    private func beautifyPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.dsCaption.weight(.semibold))
            .foregroundStyle(theme.inkSecondary.color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .dsGlass(in: Capsule())
            .padding(.top, 8)
            .transition(.opacity)
    }

    @ViewBuilder
    var beautifyingOverlay: some View {
        if beautifying {
            ZStack {
                theme.ink.withAlpha(0.12).color.ignoresSafeArea()
                VStack(spacing: 12) {
                    BrandLoader(size: 44)
                    Text("Beautifying…").font(.dsSubheadline.weight(.semibold))
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                explainMode.toggle()
            } label: {
                Image(systemName: "lasso.badge.sparkles")
            }
            .tint(explainMode ? theme.accent.color : theme.ink.color)
            .accessibilityLabel("Circle something for NOVA to explain")

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
                Button { showScanner = true } label: {
                    Label("Scan a document", systemImage: "doc.viewfinder")
                }
                Divider()
                Button {
                    Task { await model.setAllTape(hidden: true, on: nil) }
                } label: {
                    Label("Reveal all tape", systemImage: "eye")
                }
                Button {
                    Task { await model.setAllTape(hidden: false, on: nil) }
                } label: {
                    Label("Cover all tape", systemImage: "eye.slash")
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
    /// Beautifies the focused page right now: the same engine the real-time pass
    /// uses, run on demand from the ✨ panel.
    func beautifyFocusedPage() async {
        guard let (pageID, drawing) = tracker.bestDrawing(preferring: model.focusedPageID),
              !drawing.strokes.isEmpty else {
            editorNotice = "Write something with the pencil first, then tap Beautify."
            return
        }
        beautifying = true
        defer { beautifying = false }
        let pageSize = model.page(pageID)?.logicalSize ?? PageGeometry.size
        var settings = toolState.beautify
        // The button works whether or not the live switch is on.
        settings.isEnabled = true
        var didChange = false
        await beautifier.runNow(
            pageID: pageID,
            settings: settings,
            fontName: beautifyFontName,
            pageSize: pageSize,
            drawing: { tracker.drawing(for: pageID) },
            apply: { plan, remaining in
                tracker.setDrawing(remaining, for: pageID)
                await model.apply(plan: plan, to: pageID)
                didChange = !plan.isEmpty
                // Tapping Beautify is an explicit request, so it always commits.
                return true
            }
        )
        if !didChange {
            editorNotice = "Couldn't read that handwriting. Try writing a little larger."
        }
    }

    func handlePickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        await model.insertImage(data, fileExtension: "jpg")
        photoItem = nil
    }

    func handleImportedFile(_ result: Result<URL, Error>) {
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

    func recognizeHandwriting() async {
        guard let pageID = model.focusedPageID,
              let drawing = tracker.drawing(for: pageID) else { return }
        let text = await model.recognizeText(
            pageID: pageID, drawing: drawing, language: toolState.beautify.language
        )
        if !text.isEmpty { ocrText = OCRResult(text: text) }
    }

    /// Snip finished: map the rectangle to the page under it, crop that region,
    /// and hand the PICTURE to NOVA in the sidebar.
    func handleSnip(_ region: CGRect) {
        explainMode = false
        guard region.width > 1, region.height > 1 else { return }
        let center = CGPoint(x: region.midX, y: region.midY)

        // The page under the scribble's center (fallback to the focused page).
        let target = pageFrames.first(where: { $0.value.contains(center) })
            ?? model.focusedPageID.flatMap { id in pageFrames[id].map { (id, $0) } }
        guard let (pageID, frame) = target, frame.width > 1 else { return }

        let logicalSize = model.page(pageID)?.logicalSize ?? PageGeometry.size
        let scale = frame.width / logicalSize.width
        let onPage = region.intersection(frame)
        guard onPage.width > 8, onPage.height > 8 else { return }
        let logical = CGRect(
            x: (onPage.minX - frame.minX) / scale,
            y: (onPage.minY - frame.minY) / scale,
            width: onPage.width / scale,
            height: onPage.height / scale
        )
        model.focusedPageID = pageID
        Task { await runSnipExplain(pageID: pageID, logicalRegion: logical) }
    }

    @MainActor
    func runSnipExplain(pageID: UUID, logicalRegion: CGRect) async {
        guard let page = model.page(pageID) else { return }
        let full = renderPageImage(page)
        let cropped = crop(full, to: logicalRegion, logicalSize: page.logicalSize) ?? full
        // The snip goes as a PICTURE. OCR of it would drop exactly the part that
        // usually matters — the diagram, the graph, the working laid out across
        // the page — so it is carried only as a hint for a model that can't see.
        let jpeg = NovaSnip.encode(cropped)
        let ocr = await model.ocr(image: cropped)

        if novaConversation == nil {
            novaConversation = services.makeNovaConversation()
        }
        novaConversation?.explainRegion(image: jpeg, ocrHint: ocr)
        showNova = true
    }

    /// Renders one page (paper + margin + ink + elements) to an image in its own
    /// logical page space, so the magic pen can crop a region from it.
    ///
    /// `drawing` overrides the live canvas — needed for any page whose canvas the
    /// lazy page list has already deallocated, which would otherwise render as
    /// blank paper.
    @MainActor
    func renderPageImage(
        _ page: PageRecord, scale: CGFloat = 2, drawing: PKDrawing? = nil
    ) -> UIImage {
        let logicalSize = page.logicalSize
        let pageRect = CGRect(origin: .zero, size: logicalSize)
        let ink = (drawing ?? tracker.drawing(for: page.id))?.image(from: pageRect, scale: scale)
        let content = ZStack {
            pagePaper(page)
            if let bg = backgroundImage(for: page) { Image(uiImage: bg).resizable().scaledToFit() }
            if let ink { Image(uiImage: ink).resizable().scaledToFit() }
            PageElementsLayer(
                pageID: page.id, elements: page.elements, model: model,
                toolState: toolState,
                displaySize: logicalSize, logicalSize: logicalSize,
                allowsEditing: false, editingTextID: .constant(nil)
            )
        }
        .frame(width: logicalSize.width, height: logicalSize.height)
        .environment(\.theme, theme)
        .environment(\.paperTone, paperTone)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.uiImage ?? UIImage()
    }

    /// Render every page to a PNG and push it up — with the page's playable and
    /// openable attachments — so the ClassMate ClassNotes tab shows real content.
    /// Best-effort; SyncService no-ops when signed out.
    @MainActor
    func syncPageContent() {
        let pages = model.pages
        guard !pages.isEmpty else { return }
        Task { @MainActor in
            var images: [NotebookPageImage] = []
            for (index, page) in pages.enumerated() {
                let ink = await inkForRender(page)
                guard let data = renderPageImage(page, scale: 1.5, drawing: ink).pngData() else {
                    continue
                }
                images.append(NotebookPageImage(
                    pageIndex: index,
                    dataUrl: "data:image/png;base64,\(data.base64EncodedString())",
                    attachments: attachments(for: page)
                ))
            }
            services.sync.pushPageImages(notebookID: notebook.id, images: images)
        }
    }

    /// A page's ink for rendering: the live canvas when the page is on screen,
    /// otherwise what's saved on disk. The lazy page list deallocates canvases you
    /// scrolled past (their ink is flushed on the way out), so without the disk
    /// fallback every off-screen page would sync as empty paper.
    @MainActor
    func inkForRender(_ page: PageRecord) async -> PKDrawing? {
        if let live = tracker.drawing(for: page.id) { return live }
        guard let data = await services.documentStore.pageData(
            notebook: notebook.id, page: page.id
        ) else { return nil }
        return try? PKDrawing(data: data)
    }

    /// Renders the cover page — artwork plus whatever the user drew on it — and
    /// saves it beside the pages, so the library tile, the iPhone viewer and the
    /// ClassMate ClassNotes tab all show the cover as it now looks.
    @MainActor
    func saveCoverRender() async {
        guard let cover = model.coverPage else { return }
        let ink = await inkForRender(cover)
        // ~360 px wide: enough for a Retina library tile, small enough to travel
        // inside the notebook sync body.
        let scale = 360 / max(cover.logicalSize.width, 1)
        guard let png = renderPageImage(cover, scale: scale, drawing: ink).pngData() else { return }
        try? await services.documentStore.saveCoverImage(png, for: notebook.id)
    }

    /// The page's voice notes, files and links, packaged so ClassMate can play and
    /// open them. Audio and small files travel as data URLs; links as their URL.
    @MainActor
    func attachments(for page: PageRecord) -> [NotebookPageAttachment] {
        page.elements.compactMap { element in
            switch element.kind {
            case .audio:
                guard let filename = element.payloadFilename,
                      let data = try? Data(contentsOf: model.mediaURL(filename: filename)),
                      data.count <= NotebookPageAttachment.maximumPayloadBytes else { return nil }
                return NotebookPageAttachment(
                    kind: "audio",
                    name: element.displayName ?? "Voice note",
                    durationSeconds: element.durationSeconds,
                    dataUrl: "data:audio/m4a;base64,\(data.base64EncodedString())"
                )
            case .file:
                guard let filename = element.payloadFilename,
                      let data = try? Data(contentsOf: model.mediaURL(filename: filename)),
                      data.count <= NotebookPageAttachment.maximumPayloadBytes else { return nil }
                let mime = NotebookPageAttachment.mimeType(forExtension: (filename as NSString).pathExtension)
                return NotebookPageAttachment(
                    kind: "file",
                    name: element.displayName ?? filename,
                    dataUrl: "data:\(mime);base64,\(data.base64EncodedString())"
                )
            case .link:
                guard let url = element.urlString else { return nil }
                return NotebookPageAttachment(
                    kind: "link",
                    name: element.displayName ?? url,
                    url: url
                )
            case .image, .text, .tape, .fill:
                // Nothing to play or open: these are already in the page render.
                return nil
            }
        }
    }

    /// The decoded background image for a page (imported PDF/image), or nil.
    func backgroundImage(for page: PageRecord) -> UIImage? {
        guard let filename = page.backgroundPayloadFilename else { return nil }
        if let cached = backgroundCache.image(for: filename) { return cached }
        guard let data = try? Data(contentsOf: model.mediaURL(filename: filename)),
              let image = UIImage(data: data) else { return nil }
        backgroundCache.set(image, for: filename)
        return image
    }

    func crop(_ image: UIImage, to logical: CGRect, logicalSize: CGSize) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let pixelsPerPoint = CGFloat(cg.width) / logicalSize.width
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
struct Overscroll: Equatable {
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
