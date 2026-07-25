import ClassMateTheme
import NotesAI
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// iPad notebook editor: scrolling multi-page PencilKit canvas + the draggable
/// tool rail, page manager, media/voice/text tools, ruler and NOVA layered on
/// top. Only `App/Routing` may import this module.
public struct EditorScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    private let notebook: Notebook

    @State private var model: NotebookEditorModel
    @State private var toolState = ToolState()
    @State private var tracker = ActiveCanvasTracker()

    @State private var rulerVisible = false
    @State private var explainMode = false
    @State private var showPages = false
    @State private var addingBottom = false
    @State private var addingTop = false

    // Insertion sheets/state
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showRecorder = false
    @State private var ocrText: OCRResult?
    @State private var novaConversation: NovaConversation?
    @State private var showNova = false

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
                CircleToExplainOverlay { rect in explainSelection(rect) }
                    .ignoresSafeArea()
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
        .animation(.spring(duration: 0.3), value: showPages)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            model = NotebookEditorModel(notebookID: notebook.id, store: services.documentStore)
            await model.load()
        }
        .onDisappear { services.repository.touch(notebook) }
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
                PageTemplateView(template: page.template, margin: page.margin)
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
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

}

// MARK: - Actions

extension EditorScreen {
    private func beautifyFocusedPage() async {
        guard let pageID = model.focusedPageID ?? model.pages.first?.id,
              let drawing = tracker.drawing(for: pageID) else { return }
        await model.beautify(
            pageID: pageID, drawing: drawing,
            font: toolState.beautifyFont, colorHex: theme.ink.hexString
        )
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
        Task {
            await model.insertFile(data, displayName: url.lastPathComponent, fileExtension: url.pathExtension)
        }
    }

    private func recognizeHandwriting() async {
        guard let pageID = model.focusedPageID,
              let drawing = tracker.drawing(for: pageID) else { return }
        let text = await model.recognizeText(pageID: pageID, drawing: drawing)
        if !text.isEmpty { ocrText = OCRResult(text: text) }
    }

    private func explainSelection(_ viewRect: CGRect) {
        explainMode = false
        guard let pageID = model.focusedPageID,
              let drawing = tracker.drawing(for: pageID) else {
            openNova(with: "")
            return
        }
        Task {
            // Approximate: OCR the whole page, then hand NOVA the text. The
            // drawn box tells NOVA the user cares about this region.
            let text = await model.recognizeText(pageID: pageID, drawing: drawing)
            openNova(with: text)
        }
    }

    private func openNova(with context: String) {
        let conversation = services.makeNovaConversation()
        if !context.isEmpty {
            conversation.explain(context: context)
        }
        novaConversation = conversation
        showNova = true
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
