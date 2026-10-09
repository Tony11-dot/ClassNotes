import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var dropTargeted = false

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
            .onDrop(of: [.item], delegate: LibraryDropDelegate(isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            })
            .overlay { if dropTargeted { dropHint } }
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
            if let notebook = await makeImport(kind: kind, title: title, pdf: pdf, images: images) {
                onCreated(notebook)
            } else {
                notice = "Couldn't read that — try a PDF, a photo or a scan."
            }
        }
    }

    private func makeImport(
        kind: NotebookKind, title: String, pdf: Data? = nil, images: [Data] = []
    ) async -> Notebook? {
        let created = try? await services.repository.createFromImport(
            title: title, coverColor: coverColor(for: kind), kind: kind,
            coverDesign: coverDesign(for: kind),
            pdf: pdf, images: images, shelfID: shelfID
        )
        return created ?? nil
    }

    /// A file that isn't a page (a zip, a spreadsheet): make a document and drop it
    /// on page one as an openable chip.
    private func createFileAttachmentDocument(name: String, data: Data, extension ext: String) {
        working = true
        Task {
            defer { working = false }
            guard let notebook = await makeFileAttachmentDocument(name: name, data: data, extension: ext) else {
                notice = "Couldn't import that file."
                return
            }
            onCreated(notebook)
        }
    }

    private func makeFileAttachmentDocument(name: String, data: Data, extension ext: String) async -> Notebook? {
        guard let notebook = try? await services.repository.create(
            title: name,
            coverColor: coverColor(for: .document),
            style: PageStyle(template: .blank, margin: PageMargin(position: .none), pageSize: .a4),
            kind: .document,
            coverDesign: coverDesign(for: .document),
            shelfID: shelfID
        ) else { return nil }
        await services.repository.attachFile(
            data, displayName: "\(name).\(ext)", fileExtension: ext, to: notebook.id
        )
        return notebook
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
                .font(.dsSubheadline.weight(.medium))
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
                    .font(.dsSubheadline.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
            }
            .padding(24)
            .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        }
        .transition(.opacity)
    }
}

// MARK: - Drag and drop

extension AddContentFlows {

    /// Files dragged onto the library become notebooks: each PDF its own,
    /// every photo in the drop together as one, any other file a document
    /// with it on page one. One new notebook opens; several stay on the shelf
    /// for the user to see, since opening one would hide the others.
    func handleDrop(_ providers: [NSItemProvider]) {
        working = true
        Task {
            defer { working = false }
            var made: [Notebook] = []
            var images: [(data: Data, name: String)] = []
            var unreadable = 0
            for provider in providers {
                let item = await DropLoader.load(provider)
                if case .image(let data, let name, _) = item {
                    images.append((data, name))
                } else if let item, let notebook = await notebook(from: item) {
                    made.append(notebook)
                } else {
                    unreadable += 1
                }
            }
            if !images.isEmpty {
                let title = images.count == 1 ? (images[0].name.isEmpty ? "Image" : images[0].name) : "Images"
                if let notebook = await makeImport(kind: .image, title: title, images: images.map(\.data)) {
                    made.append(notebook)
                } else {
                    unreadable += images.count
                }
            }
            if made.count == 1, unreadable == 0 {
                onCreated(made[0])
            } else if made.isEmpty {
                notice = "Couldn't read that — try a PDF, a photo or a file."
            } else {
                let added = made.count == 1 ? "1 notebook added" : "\(made.count) notebooks added"
                notice = unreadable == 0 ? added : "\(added); \(unreadable) couldn't be read"
            }
        }
    }

    /// One notebook for a dropped PDF or file; nil for anything else.
    private func notebook(from item: DroppedItem) async -> Notebook? {
        switch item {
        case .pdf(let data, let name):
            await makeImport(kind: .document, title: name.isEmpty ? "PDF" : name, pdf: data)
        case .file(let data, let name, let ext):
            await makeFileAttachmentDocument(
                name: (name as NSString).deletingPathExtension, data: data, extension: ext
            )
        case .image, .link, .text:
            nil
        }
    }

    var dropHint: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(theme.accent.color, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .background(theme.accent.withAlpha(0.06).color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                Label("Drop to add to your library", systemImage: "square.and.arrow.down")
                    .font(.dsHeadline)
                    .foregroundStyle(theme.accent.color)
            }
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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

/// Accepts only drags that can become a notebook (`DropRouting.libraryKind`),
/// so a notebook dragged towards a shelf isn't caught by the library behind it.
struct LibraryDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let perform: ([NSItemProvider]) -> Void

    private func accepted(_ info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: [.item]).filter {
            DropRouting.libraryKind(for: $0.registeredTypeIdentifiers) != nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool { !accepted(info).isEmpty }
    func dropEntered(info: DropInfo) { isTargeted = !accepted(info).isEmpty }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        accepted(info).isEmpty ? DropProposal(operation: .forbidden) : DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = accepted(info)
        guard !providers.isEmpty else { return false }
        perform(providers)
        return true
    }
}
