import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// iPhone library: a read-only list. No creation, no editing — notebooks are
/// made on iPad; here they're browsed, viewed and shared.
public struct LibraryListScreen<Destination: View>: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]

    private let destination: (Notebook) -> Destination

    @State private var searchText = ""
    @State private var showSettings = false
    @State private var selection = LibrarySelection()
    @State private var confirmBulkDelete = false

    public init(@ViewBuilder destination: @escaping (Notebook) -> Destination) {
        self.destination = destination
    }

    private var filtered: [Notebook] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notebooks }
        return notebooks.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if notebooks.isEmpty {
                    EmptyStateView(
                        systemImage: "book.closed",
                        title: "No notebooks yet",
                        message: "Notebooks you create on iPad appear here to read and share."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(theme.surface.color)
            .navigationTitle("Library")
            .navigationDestination(for: Notebook.self) { notebook in
                destination(notebook)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                if !notebooks.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selection.isActive ? "Done" : "Select") {
                            if selection.isActive {
                                selection.end()
                            } else {
                                selection.selectAll([])
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if selection.isActive {
                    LibrarySelectionBar(
                        selection: selection,
                        shelves: [],
                        allIDs: filtered.map(\.id),
                        onDelete: { confirmBulkDelete = true },
                        onMove: { _ in }
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.28), value: selection.isActive)
            .confirmationDialog(
                selection.count == 1
                    ? "Delete 1 notebook from this iPhone?"
                    : "Delete \(selection.count) notebooks from this iPhone?",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let doomed = selection.selected(from: filtered)
                    selection.end()
                    Task { try? await services.repository.delete(doomed) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        // iOS 26 places search at the bottom edge on iPhone automatically.
        .searchable(text: $searchText, prompt: "Search notebooks")
        .sheet(isPresented: $showSettings) { SettingsScreen() }
    }

    private var list: some View {
        List(filtered) { notebook in
            row(notebook)
                .listRowBackground(theme.surfaceRaised.color)
        }
        .scrollContentBackground(.hidden)
    }

    /// While selecting, the row picks up instead of navigating — a NavigationLink
    /// would push the viewer out from under the tick the user just tapped.
    @ViewBuilder
    private func row(_ notebook: Notebook) -> some View {
        if selection.isActive {
            Button {
                selection.toggle(notebook.id)
            } label: {
                rowContent(notebook)
                    .librarySelectable(isActive: true, isSelected: selection.contains(notebook.id))
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: notebook) {
                rowContent(notebook)
            }
            .contextMenu {
                Button {
                    selection.begin(with: notebook.id)
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private func rowContent(_ notebook: Notebook) -> some View {
        HStack(spacing: 14) {
                    NotebookCoverTile(notebook: notebook, showsTitle: false)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(notebook.title)
                        } icon: {
                            if notebook.kind != .notebook {
                                Image(systemName: notebook.kind.symbolName)
                            }
                        }
                            .font(.dsBody.weight(.medium))
                            .foregroundStyle(theme.ink.color)
                        Text(notebook.updatedAt, format: .dateTime.day().month().year())
                            .font(.dsCaption)
                            .foregroundStyle(theme.inkSecondary.color)
            }
        }
    }
}
