import ClassMateTheme
import NotesAI
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// iPad notebook editor: scrolling multi-page PencilKit canvas + the media,
/// voice, text, ruler and NOVA tools layered on top. Only `App/Routing` may
/// import this module.
public struct EditorScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    private let notebook: Notebook

    @State private var model: NotebookEditorModel
    @State private var toolState = ToolState()
    @State private var tracker = ActiveCanvasTracker()

    @State private var rulerVisible = false
    @State private var explainMode = false
    @State private var addingPage = false

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
        ZStack {
            theme.surface.color.ignoresSafeArea()
            pageScroll
            if model.manifest == nil {
                BrandLoader(size: 56)
            }
            if rulerVisible {
                RulerOverlay(isVisible: $rulerVisible).ignoresSafeArea()
            }
            if explainMode {
                CircleToExplainOverlay { rect in
                    explainSelection(rect)
                }
                .ignoresSafeArea()
            }
        }
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
        ScrollView {
            LazyVStack(spacing: 32) {
                ForEach(model.pages) { page in
                    pageView(page)
                }
                addPageButton
            }
            .padding(.vertical, 28)
        }
    }

    private func pageView(_ page: PageRecord) -> some View {
        GeometryReader { geo in
            ZStack {
                PageTemplateView(template: page.template)
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

    private var addPageButton: some View {
        Button {
            guard !addingPage else { return }
            addingPage = true
            Task {
                await model.addPage(template: notebook.defaultTemplate)
                addingPage = false
            }
        } label: {
            Label("Add page", systemImage: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .disabled(addingPage)
        .padding(.bottom, 40)
    }

    // MARK: - Toolbar

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

            Button {
                rulerVisible.toggle()
            } label: {
                Image(systemName: "ruler")
            }
            .tint(rulerVisible ? theme.accent.color : theme.ink.color)
            .accessibilityLabel("Ruler")

            Menu {
                Button { showPhotoPicker = true } label: { Label("Photo", systemImage: "photo") }
                Button { showFileImporter = true } label: { Label("File", systemImage: "doc") }
                Button { showRecorder = true } label: { Label("Voice note", systemImage: "mic") }
                Button { Task { await recognizeHandwriting() } } label: {
                    Label("Handwriting → text", systemImage: "text.viewfinder")
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .accessibilityLabel("Insert")
        }
    }

    // MARK: - Actions

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

/// Identifiable wrapper so recognized text can drive a `.sheet(item:)`.
struct OCRResult: Identifiable {
    let id = UUID()
    let text: String
}
