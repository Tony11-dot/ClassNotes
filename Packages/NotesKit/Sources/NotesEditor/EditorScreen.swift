import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// iPad notebook editor: vertically scrolling multi-page PencilKit canvas with
/// the floating glass tool palette. Only `App/Routing` may import this module.
public struct EditorScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    private let notebook: Notebook

    @State private var manifest: NotebookManifest?
    @State private var toolState = ToolState()
    @State private var tracker = ActiveCanvasTracker()
    @State private var addingPage = false

    public init(notebook: Notebook) {
        self.notebook = notebook
    }

    public var body: some View {
        Group {
            if let manifest {
                pages(manifest)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.surface.color)
        .overlay {
            ToolPaletteView(toolState: toolState, tracker: tracker)
        }
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addPage()
                } label: {
                    Image(systemName: "plus.rectangle.portrait")
                }
                .accessibilityLabel("Add page")
                .disabled(addingPage)
            }
        }
        .task {
            manifest = try? await services.documentStore.manifest(for: notebook.id)
        }
        .onDisappear {
            services.repository.touch(notebook)
        }
    }

    private func pages(_ manifest: NotebookManifest) -> some View {
        ScrollView {
            LazyVStack(spacing: 32) {
                ForEach(Array(manifest.pages.enumerated()), id: \.element.id) { index, page in
                    pageView(page, number: index + 1)
                }
                addPageButton
            }
            .padding(.vertical, 28)
        }
    }

    private func pageView(_ page: PageRecord, number: Int) -> some View {
        ZStack {
            PageTemplateView(template: page.template)
            CanvasPageView(
                notebookID: notebook.id,
                page: page,
                toolState: toolState,
                tracker: tracker
            )
        }
        .aspectRatio(
            PageGeometry.size.width / PageGeometry.size.height,
            contentMode: .fit
        )
        .frame(maxWidth: 840)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        .padding(.horizontal, 40)
        .accessibilityLabel("Page \(number)")
    }

    private var addPageButton: some View {
        Button {
            addPage()
        } label: {
            Label("Add page", systemImage: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .disabled(addingPage)
        .padding(.bottom, 40)
    }

    private func addPage() {
        guard !addingPage else { return }
        addingPage = true
        Task {
            defer { addingPage = false }
            manifest = try? await services.documentStore.addPage(
                to: notebook.id,
                template: notebook.defaultTemplate
            )
        }
    }
}
