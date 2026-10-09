import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI
import UIKit

/// Read-only viewer for a notebook that exists on the account but has no
/// local ink package on this device (`Notebook.isRemoteOnly`) — created on
/// another device and discovered through the library pull.
///
/// Simpler than `NotebookViewerScreen`: there's no `PageRecord`/`PageElement`
/// geometry to composite here, only the flat rendered PNG the source device
/// already pushed (`GET /classnotes/notebooks/:id/pages`) plus whatever's
/// playable or openable on it. A code block, an image, typeset text — all of
/// it is already baked into that render, the same way it's baked into the
/// PDF export; only audio/file/link attachments need their own row, since
/// those are the one thing a flat picture can't play or open.
///
/// On the iPad it also offers to bring the notebook over ("Edit on this iPad",
/// `NotebookRepository.adoptRemote`). Without that, a notebook written on
/// another device was something you could look at and never write in, with
/// nothing on screen to say why.
public struct RemoteNotebookViewerScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    private let notebook: Notebook
    /// The iPad edits; the iPhone only ever views.
    private let allowsEditing: Bool

    public init(notebook: Notebook, allowsEditing: Bool = false) {
        self.notebook = notebook
        self.allowsEditing = allowsEditing
    }

    @State private var pages: [RemoteNotebookCache.Page] = []
    @State private var pageImages: [Int: UIImage] = [:]
    @State private var isLoading = true
    @State private var confirmingEdit = false
    @State private var isBringingOver = false
    @State private var bringOverFailed = false

    public var body: some View {
        Group {
            if isLoading, pages.isEmpty {
                BrandLoader(size: 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .font(.dsSystem(size: 32))
                        .foregroundStyle(theme.inkSecondary.color)
                    Text("Can't reach this notebook right now")
                        .font(.dsSubheadline)
                        .foregroundStyle(theme.inkSecondary.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 24) {
                        ForEach(pages) { page in
                            pageView(page)
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 12)
                }
                .refreshable { await load() }
            }
        }
        .overlay {
            if isBringingOver {
                VStack(spacing: 14) {
                    BrandLoader(size: 52)
                    Text("Bringing the pages over…")
                        .font(.dsSubheadline)
                        .foregroundStyle(theme.inkSecondary.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surface.color.opacity(0.92))
            }
        }
        .background(theme.surface.color)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if allowsEditing {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        confirmingEdit = true
                    } label: {
                        Label("Edit on this iPad", systemImage: "pencil")
                    }
                    .disabled(isBringingOver)
                }
            }
        }
        .confirmationDialog(
            "Edit this notebook on this iPad?", isPresented: $confirmingEdit, titleVisibility: .visible
        ) {
            Button("Edit on this iPad") { Task { await bringOver() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "It was written on another device, and only pictures of its pages are here. "
                    + "Each page becomes a picture you can write on; what's already on it can't be "
                    + "erased or moved. The device it was written on keeps the original."
            )
        }
        .alert("Couldn't bring this notebook over", isPresented: $bringOverFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check that you're online and signed in, then try again. Nothing was changed.")
        }
        .task { await load() }
    }

    /// "Edit on this iPad": a COMPLETE fresh copy of the pages, then a package
    /// built from them. When it lands the row stops being remote-only, and the
    /// route above this screen swaps it for the editor.
    private func bringOver() async {
        guard let token = services.auth.token else {
            bringOverFailed = true
            return
        }
        isBringingOver = true
        defer { isBringingOver = false }
        do {
            let cache = services.remoteNotebookCache
            let fresh = try await cache.freshPages(for: notebook.id, token: token)
            let cover = await cache.coverURL(for: notebook.id).flatMap { try? Data(contentsOf: $0) }
            try await services.repository.adoptRemote(notebook, pages: fresh, coverRender: cover)
        } catch {
            bringOverFailed = true
        }
    }

    private func pageView(_ page: RemoteNotebookCache.Page) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let image = pageImages[page.id] {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    theme.surfaceRaised.color
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.separator.color, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 6, y: 3)

            if !page.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(page.attachments.enumerated()), id: \.offset) { _, attachment in
                        attachmentRow(attachment)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentRow(_ attachment: RemoteNotebookCache.Attachment) -> some View {
        switch attachment.kind {
        case "audio":
            if let url = attachment.fileURL {
                VoiceBubbleView(
                    url: url, duration: attachment.durationSeconds ?? 0, seed: attachment.name.hashValue
                )
            }
        case "link":
            if let string = attachment.linkURL, let url = URL(string: string) {
                Link(destination: url) {
                    chip(systemImage: "link", title: attachment.name)
                }
            }
        default:
            if let url = attachment.fileURL {
                ShareLink(item: url) {
                    chip(systemImage: "doc.fill", title: attachment.name)
                }
            }
        }
    }

    private func chip(systemImage: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(theme.accent.color)
            Text(title)
                .font(.dsFootnote.weight(.medium))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
    }

    private func load() async {
        guard let token = services.auth.token else {
            isLoading = false
            return
        }
        let fetched = await services.remoteNotebookCache.pages(for: notebook.id, token: token)
        var images: [Int: UIImage] = [:]
        for page in fetched {
            if let data = try? Data(contentsOf: page.imageURL), let image = UIImage(data: data) {
                images[page.id] = image
            }
        }
        pages = fetched
        pageImages = images
        isLoading = false
    }
}
