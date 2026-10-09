import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// One notebook's cover in the grid, with everything you can do to it. The
/// shelf bar across the top is `LibraryShelfBar.swift`.
///
/// Split out of `LibraryGridScreen` so neither file is the 400-line screen that
/// nobody wants to open. Members these use are internal rather than private for
/// exactly that reason — `private` in Swift is file-scoped.
extension LibraryGridScreen {
    func coverCell(_ notebook: Notebook) -> some View {
        Button {
            // While selecting, a tap picks up and puts down instead of opening.
            if selection.isActive {
                selection.toggle(notebook.id)
                return
            }
            services.repository.touch(notebook)
            opened = LibraryOpenRequest(notebook: notebook, pageID: nil)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                NotebookCoverTile(notebook: notebook)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                    .overlay(alignment: .topTrailing) {
                        if notebook.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.dsCaption)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.45), radius: 3)
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        // So a notebook set to View Only reads as deliberately
                        // read-only, not indistinguishable from any other tile.
                        if notebook.isViewOnly {
                            Image(systemName: "eye.fill")
                                .font(.dsCaption)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.45), radius: 3)
                                .padding(8)
                        }
                    }
                HStack(spacing: 5) {
                    // A board / import reads as itself, not as "just a notebook".
                    if notebook.kind != .notebook {
                        Image(systemName: notebook.kind.symbolName)
                            .font(.dsCaption2)
                            .foregroundStyle(theme.accent.color)
                    }
                    Text(notebook.showsCover ? notebook.title : "Untitled cover off")
                        .font(.dsSubheadline.weight(.medium))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                }
                Text(notebook.updatedAt, format: .dateTime.day().month().year())
                    .font(.dsCaption)
                    .foregroundStyle(theme.inkSecondary.color)
            }
        }
        .buttonStyle(.plain)
        .librarySelectable(isActive: selection.isActive, isSelected: selection.contains(notebook.id))
        // Drag a cover onto a shelf or a tag in the bar to file it there.
        .draggable(notebook.id.uuidString) {
            NotebookCoverTile.dragPreview(notebook, services: services, theme: theme)
        }
        .contextMenu { coverMenu(notebook) }
    }

    /// Everything you can do to one notebook, from its cover.
    @ViewBuilder
    private func coverMenu(_ notebook: Notebook) -> some View {
        Button {
            selection.begin(with: notebook.id)
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        Button {
            try? services.repository.toggleFavorite(notebook)
        } label: {
            Label(
                notebook.isFavorite ? "Remove from favourites" : "Add to favourites",
                systemImage: notebook.isFavorite ? "star.slash" : "star"
            )
        }
        Button {
            renameText = notebook.title
            renameTarget = notebook
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            exportPDF(notebook)
        } label: {
            Label("Export as PDF", systemImage: "square.and.arrow.up")
        }
        if !notebook.isRemoteOnly {
            Button {
                try? services.repository.setViewOnly(!notebook.isViewOnly, for: notebook)
            } label: {
                Label(
                    notebook.isViewOnly ? "Make Editable" : "View Only",
                    systemImage: notebook.isViewOnly ? "pencil" : "eye"
                )
            }
        }
        organiseMenu(notebook)
    }

    /// Where it's filed, its tags, and deleting it.
    @ViewBuilder
    private func organiseMenu(_ notebook: Notebook) -> some View {
        Menu {
            Button("None") { services.repository.assign(notebook, toShelf: nil) }
            ForEach(shelves) { shelf in
                Button(shelfPathName(shelf.id)) { services.repository.assign(notebook, toShelf: shelf.id) }
            }
        } label: {
            Label("Move to shelf", systemImage: "tray.full")
        }
        Button {
            tagTarget = notebook
        } label: {
            Label(notebook.tags.isEmpty ? "Add tags" : "Tags", systemImage: "tag")
        }
        Button(role: .destructive) {
            deleteTarget = notebook
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}
