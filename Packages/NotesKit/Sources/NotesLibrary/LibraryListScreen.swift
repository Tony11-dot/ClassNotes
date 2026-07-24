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
            }
        }
        // iOS 26 places search at the bottom edge on iPhone automatically.
        .searchable(text: $searchText, prompt: "Search notebooks")
        .sheet(isPresented: $showSettings) { SettingsScreen() }
    }

    private var list: some View {
        List(filtered) { notebook in
            NavigationLink(value: notebook) {
                HStack(spacing: 14) {
                    NotebookCoverView(
                        title: "",
                        coverColor: ThemeColor(hex: notebook.coverColorHex) ?? theme.accent
                    )
                    .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notebook.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(theme.ink.color)
                        Text(notebook.updatedAt, format: .dateTime.day().month().year())
                            .font(.caption)
                            .foregroundStyle(theme.inkSecondary.color)
                    }
                }
            }
            .listRowBackground(theme.surfaceRaised.color)
        }
        .scrollContentBackground(.hidden)
    }
}
