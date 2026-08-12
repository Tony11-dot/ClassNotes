import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// iPad library: themed cover grid with a floating glass toolbar.
///
/// The editor destination is injected by the routing layer — this module never
/// imports NotesEditor, so the iPhone build path can't reach editing code.
public struct LibraryGridScreen<Destination: View>: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]
    @Query(sort: \Shelf.sortIndex) private var shelves: [Shelf]

    private let destination: (Notebook) -> Destination

    @State private var opened: Notebook?
    @State private var addChoice: AddContentChoice?
    @State private var showSettings = false
    @State private var renameTarget: Notebook?
    @State private var renameText = ""
    @State private var deleteTarget: Notebook?
    @State private var selectedShelf: UUID?
    @State private var showNewShelf = false
    @State private var showAddBooks = false
    @State private var selection = LibrarySelection()
    @State private var confirmBulkDelete = false

    public init(@ViewBuilder destination: @escaping (Notebook) -> Destination) {
        self.destination = destination
    }

    private var visibleNotebooks: [Notebook] {
        guard let selectedShelf else { return notebooks }
        return notebooks.filter { $0.shelfID == selectedShelf }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !shelves.isEmpty {
                    shelfBar
                }
                Group {
                    if visibleNotebooks.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.color)
            .navigationTitle("Library")
            .navigationDestination(item: $opened) { notebook in
                destination(notebook)
            }
            .overlay(alignment: .bottom) {
                if !selection.isActive { floatingToolbar }
            }
            // The bar is a safe-area INSET, not an overlay: it reserves its own
            // room instead of floating over whatever the system has already put
            // at the bottom edge, so nothing lands on top of its buttons.
            .safeAreaInset(edge: .bottom) {
                if selection.isActive {
                    LibrarySelectionBar(
                        selection: selection,
                        shelves: shelves,
                        allIDs: visibleNotebooks.map(\.id),
                        onDelete: { confirmBulkDelete = true },
                        onMove: { shelfID in
                            try? services.repository.setShelf(
                                shelfID, for: selection.selected(from: visibleNotebooks)
                            )
                            selection.end()
                        }
                    )
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.28), value: selection.isActive)
        }
        .addContentFlows(choice: $addChoice, shelfID: selectedShelf) { notebook in
            opened = notebook
        }
        .sheet(isPresented: $showSettings) { SettingsScreen() }
        .sheet(isPresented: $showNewShelf) { NewShelfSheet() }
        .sheet(isPresented: $showAddBooks) {
            if let selectedShelf { AddBooksToShelfSheet(shelfID: selectedShelf) }
        }
        .alert("Rename notebook", isPresented: renameAlertBinding) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    try? services.repository.rename(target, to: renameText)
                }
                renameTarget = nil
            }
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.title ?? "")”? Its pages will be removed from this iPad.",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Notebook", role: .destructive) {
                if let target = deleteTarget {
                    Task { try? await services.repository.delete(target) }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
        .confirmationDialog(
            selection.count == 1
                ? "Delete 1 notebook? Its pages will be removed from this iPad."
                : "Delete \(selection.count) notebooks? Their pages will be removed from this iPad.",
            isPresented: $confirmBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let doomed = selection.selected(from: visibleNotebooks)
                selection.end()
                Task { try? await services.repository.delete(doomed) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 28)],
                spacing: 28
            ) {
                ForEach(visibleNotebooks) { notebook in
                    coverCell(notebook)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
    }

    private var shelfBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                shelfChip(title: "All", symbol: "square.grid.2x2", color: theme.accent, isSelected: selectedShelf == nil) {
                    selectedShelf = nil
                }
                ForEach(shelves) { shelf in
                    shelfChip(
                        title: shelf.name,
                        symbol: shelf.symbolName,
                        color: ThemeColor(hex: shelf.colorHex) ?? theme.accent,
                        isSelected: selectedShelf == shelf.id
                    ) {
                        selectedShelf = shelf.id
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            if selectedShelf == shelf.id { selectedShelf = nil }
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

    private func shelfChip(
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

    private func coverCell(_ notebook: Notebook) -> some View {
        Button {
            // While selecting, a tap picks up and puts down instead of opening.
            if selection.isActive {
                selection.toggle(notebook.id)
                return
            }
            services.repository.touch(notebook)
            opened = notebook
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                NotebookCoverTile(notebook: notebook)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
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
                renameText = notebook.title
                renameTarget = notebook
            } label: {
                Label("Rename", systemImage: "pencil")
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

    @ViewBuilder
    private var emptyState: some View {
        if selectedShelf != nil {
            VStack(spacing: 20) {
                EmptyStateView(
                    systemImage: "tray",
                    title: "This shelf is empty",
                    message: "Add notebooks you already have, or create a new one right here."
                )
                HStack(spacing: 12) {
                    Button {
                        showAddBooks = true
                    } label: {
                        Label("Add books", systemImage: "plus.rectangle.on.folder")
                            .font(.dsSubheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(theme.accent.color, in: Capsule())
                            .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                    }
                    Button {
                        addChoice = .notebook
                    } label: {
                        Label("New notebook", systemImage: "plus")
                            .font(.dsSubheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(theme.surfaceRaised.color, in: Capsule())
                            .foregroundStyle(theme.ink.color)
                    }
                }
                .buttonStyle(.plain)
            }
        } else {
            EmptyStateView(
                systemImage: "book.closed",
                title: "No notebooks yet",
                message: "Tap + for a quick note, a full notebook, a whiteboard, or to bring in a photo, file or scan."
            )
        }
    }

    private var floatingToolbar: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                AddContentMenu { choice in addChoice = choice }
                DSGlassIconButton("New shelf", systemImage: "tray.and.arrow.down") {
                    showNewShelf = true
                }
                if selectedShelf != nil {
                    DSGlassIconButton("Add books to shelf", systemImage: "plus.rectangle.on.folder") {
                        showAddBooks = true
                    }
                }
                DSGlassIconButton("Settings", systemImage: "gearshape") {
                    showSettings = true
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .dsGlass(in: Capsule(), interactive: true)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .padding(.bottom, 24)
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }
}
