import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesPaywall
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

    private let destination: (Notebook) -> Destination

    @State private var opened: Notebook?
    @State private var showCreate = false
    @State private var showSettings = false
    @State private var showLimitPaywall = false
    @State private var renameTarget: Notebook?
    @State private var renameText = ""
    @State private var deleteTarget: Notebook?

    public init(@ViewBuilder destination: @escaping (Notebook) -> Destination) {
        self.destination = destination
    }

    public var body: some View {
        NavigationStack {
            Group {
                if notebooks.isEmpty {
                    emptyState
                } else {
                    grid
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
        .sheet(isPresented: $showCreate) { CreateNotebookSheet() }
        .sheet(isPresented: $showSettings) { SettingsScreen() }
        .sheet(isPresented: $showLimitPaywall) {
            PaywallView(highlighting: .unlimitedNotebooks)
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
                ForEach(notebooks) { notebook in
                    coverCell(notebook)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
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
            Button(role: .destructive) {
                deleteTarget = notebook
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "book.closed",
            title: "No notebooks yet",
            message: "Tap + to create your first notebook. Covers, paper and ink all follow your theme."
        )
    }

    private var floatingToolbar: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                DSGlassIconButton("New notebook", systemImage: "plus") {
                    if services.repository.canCreateNotebook(currentCount: notebooks.count) {
                        showCreate = true
                    } else {
                        showLimitPaywall = true
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
