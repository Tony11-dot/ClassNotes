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
public struct RemoteNotebookViewerScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    private let notebook: Notebook

    public init(notebook: Notebook) {
        self.notebook = notebook
    }

    @State private var pages: [RemoteNotebookCache.Page] = []
    @State private var pageImages: [Int: UIImage] = [:]
    @State private var isLoading = true

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
        .background(theme.surface.color)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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
