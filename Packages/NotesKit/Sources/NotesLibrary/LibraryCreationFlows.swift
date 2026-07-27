import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PhotosUI
import SwiftUI

/// The plumbing behind the library's `+`: everything except the full New Notebook
/// sheet, which is a screen of its own.
///
/// Attached once to the library, it owns the picker/scanner presentations and turns
/// each result into a document. A quick note skips every question; an image, file
/// or scan becomes an annotatable document straight away.
struct AddContentFlows: ViewModifier {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    @Binding var choice: AddContentChoice?
    let shelfID: UUID?
    /// Called with the finished document so the library can push into it.
    let onCreated: (Notebook) -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var working = false
    @State private var notice: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding(for: [.notebook, .whiteboard])) {
                NewNotebookSheet(
                    shelfID: shelfID,
                    kind: choice == .whiteboard ? .whiteboard : .notebook,
                    onCreated: onCreated
                )
            }
            .photosPicker(
                isPresented: sheetBinding(for: [.image]),
                selection: $photoItem,
                matching: .images
            )
            .sheet(isPresented: sheetBinding(for: [.scan])) {
                DocumentScannerView { images in
                    createImport(kind: .scan, title: "Scan", images: images)
                }
            }
            .fileImporter(
                isPresented: sheetBinding(for: [.file]),
                allowedContentTypes: [.item]
            ) { result in
                handleFile(result)
            }
            .onChange(of: choice) { _, new in
                // A quick note needs no UI at all — make it and open it.
                if new == .quickNote {
                    choice = nil
                    createQuickNote()
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    createImport(kind: .image, title: "Image", images: [data])
                }
            }
            .overlay(alignment: .top) { noticeBanner }
            .overlay { if working { progressOverlay } }
    }

    /// A binding that is true while `choice` is one of `kinds`, and clears it on
    /// dismissal — one source of truth for six different presentations.
    private func sheetBinding(for kinds: [AddContentChoice]) -> Binding<Bool> {
        Binding(
            get: { choice.map(kinds.contains) ?? false },
            set: { presented in
                if !presented, choice.map(kinds.contains) == true { choice = nil }
            }
        )
    }

    // MARK: - Creation

    private func createQuickNote() {
        working = true
        Task {
            defer { working = false }
            let color = theme.coverPalette.first ?? theme.accent
            if let notebook = try? await services.repository.createQuickNote(
                coverColor: color, shelfID: shelfID
            ) {
                onCreated(notebook)
            } else {
                notice = "Couldn't create that note."
            }
        }
    }

    private func handleFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            notice = "Couldn't read that file."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "pdf" {
            createImport(kind: .document, title: name, pdf: data)
        } else if let image = UIImage(data: data), image.size.width > 0 {
            createImport(kind: .image, title: name, images: [data])
        } else {
            // Not a page-shaped file — a notebook with the file dropped on page one
            // still lets the student annotate around it.
            createFileAttachmentDocument(name: name, data: data, extension: url.pathExtension)
        }
    }

    private func createImport(
        kind: NotebookKind, title: String, pdf: Data? = nil, images: [Data] = []
    ) {
        working = true
        Task {
            defer { working = false }
            let color = coverColor(for: kind)
            let created = try? await services.repository.createFromImport(
                title: title, coverColor: color, kind: kind,
                coverDesign: coverDesign(for: kind),
                pdf: pdf, images: images, shelfID: shelfID
            )
            if let notebook = created ?? nil {
                onCreated(notebook)
            } else {
                notice = "Couldn't read that — try a PDF, a photo or a scan."
            }
        }
    }

    /// A file that isn't a page (a zip, a spreadsheet): make a document and drop it
    /// on page one as an openable chip.
    private func createFileAttachmentDocument(name: String, data: Data, extension ext: String) {
        working = true
        Task {
            defer { working = false }
            guard let notebook = try? await services.repository.create(
                title: name,
                coverColor: coverColor(for: .document),
                style: PageStyle(template: .blank, margin: PageMargin(position: .none), pageSize: .a4),
                kind: .document,
                coverDesign: coverDesign(for: .document),
                shelfID: shelfID
            ) else {
                notice = "Couldn't import that file."
                return
            }
            await services.repository.attachFile(
                data, displayName: "\(name).\(ext)", fileExtension: ext, to: notebook.id
            )
            onCreated(notebook)
        }
    }

    /// Imported documents get a cover that hints at what's inside.
    private func coverColor(for kind: NotebookKind) -> ThemeColor {
        let palette = theme.coverPalette
        guard !palette.isEmpty else { return theme.accent }
        switch kind {
        case .notebook, .whiteboard: return palette[0]
        case .image: return palette[min(3, palette.count - 1)]
        case .document: return palette[min(5, palette.count - 1)]
        case .scan: return palette[min(7, palette.count - 1)]
        }
    }

    private func coverDesign(for kind: NotebookKind) -> CoverDesign {
        switch kind {
        case .image: .halo
        case .document: .labelled
        case .scan: .index
        case .whiteboard: .gridlines
        case .notebook: .default
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice {
            Text(notice)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(theme.accent.color, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(2.6))
                    self.notice = nil
                }
        }
    }

    private var progressOverlay: some View {
        ZStack {
            theme.ink.withAlpha(0.1).color.ignoresSafeArea()
            VStack(spacing: 12) {
                BrandLoader(size: 44)
                Text("Preparing…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
            }
            .padding(24)
            .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        }
        .transition(.opacity)
    }
}

extension View {
    /// Attaches the library's `+` flows. `choice` drives which one is presented.
    func addContentFlows(
        choice: Binding<AddContentChoice?>,
        shelfID: UUID?,
        onCreated: @escaping (Notebook) -> Void
    ) -> some View {
        modifier(AddContentFlows(choice: choice, shelfID: shelfID, onCreated: onCreated))
    }
}
