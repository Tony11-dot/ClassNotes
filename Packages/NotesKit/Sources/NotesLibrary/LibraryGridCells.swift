import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// The grid's cells: the shelf bar across the top, and one notebook's cover with
/// everything you can do to it.
///
/// Split out of `LibraryGridScreen` so neither file is the 400-line screen that
/// nobody wants to open. Members these use are internal rather than private for
/// exactly that reason — `private` in Swift is file-scoped.
extension LibraryGridScreen {
    var shelfBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                shelfChip(
                    title: "All", symbol: "square.grid.2x2", color: theme.accent,
                    isSelected: selectedShelf == .all
                ) {
                    selectedShelf = .all
                }
                if favoritesCount > 0 {
                    shelfChip(
                        title: "Favourites", symbol: "star.fill", color: theme.accent,
                        isSelected: selectedShelf == .favorites
                    ) {
                        selectedShelf = .favorites
                    }
                }
                ForEach(shelves) { shelf in
                    shelfChip(
                        title: shelf.name,
                        symbol: shelf.symbolName,
                        color: ThemeColor(hex: shelf.colorHex) ?? theme.accent,
                        isSelected: selectedShelf == .shelf(shelf.id)
                    ) {
                        selectedShelf = .shelf(shelf.id)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            if selectedShelf == .shelf(shelf.id) { selectedShelf = .all }
                            try? services.repository.deleteShelf(shelf)
                        } label: {
                            Label("Delete shelf", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
    }

    func shelfChip(
        title: String,
        symbol: String,
        color: ThemeColor,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.dsSubheadline.weight(.medium))
                .foregroundStyle(isSelected ? theme.contrastingInk(on: color).color : theme.ink.color)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected ? color.color : theme.surfaceRaised.color,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    func coverCell(_ notebook: Notebook) -> some View {
        Button {
            // While selecting, a tap picks up and puts down instead of opening.
            if selection.isActive {
                selection.toggle(notebook.id)
                return
            }
            services.repository.touch(notebook)
            opened = OpenRequest(notebook: notebook, pageID: nil)
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
        .contextMenu {
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
            Menu {
                Button("None") { services.repository.assign(notebook, toShelf: nil) }
                ForEach(shelves) { shelf in
                    Button(shelf.name) { services.repository.assign(notebook, toShelf: shelf.id) }
                }
            } label: {
                Label("Move to shelf", systemImage: "tray.full")
            }
            Button(role: .destructive) {
                deleteTarget = notebook
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
