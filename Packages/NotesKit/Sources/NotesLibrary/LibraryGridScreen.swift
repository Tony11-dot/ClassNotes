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
    @State private var showCreate = false
    @State private var showSettings = false
    @State private var renameTarget: Notebook?
    @State private var renameText = ""
    @State private var deleteTarget: Notebook?
    @State private var selectedShelf: UUID?
    @State private var showNewShelf = false
    @State private var showAddBooks = false

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
            .overlay(alignment: .bottom) { floatingToolbar }
        }
        .sheet(isPresented: $showCreate) { CreateNotebookSheet(shelfID: selectedShelf) }
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
                .font(.subheadline.weight(.medium))
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
            services.repository.touch(notebook)
            opened = notebook
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                NotebookCoverView(
                    title: notebook.title,
                    coverColor: ThemeColor(hex: notebook.coverColorHex) ?? theme.accent
                )
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                Text(notebook.updatedAt, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(theme.inkSecondary.color)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
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
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(theme.accent.color, in: Capsule())
                            .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                    }
                    Button {
                        showCreate = true
                    } label: {
                        Label("New notebook", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
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
                message: "Tap + to create your first notebook. Covers, paper and ink all follow your theme."
            )
        }
    }

    private var floatingToolbar: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                DSGlassIconButton("New notebook", systemImage: "plus") {
                    showCreate = true
                }
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
