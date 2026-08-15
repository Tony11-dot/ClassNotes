import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// Picker to add existing notebooks to a shelf: lists every notebook NOT
/// already in the shelf, tap to file it. Fixes the old flow where a shelf could
/// only ever show books already in it (so an empty shelf offered nothing to add).
struct AddBooksToShelfSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]

    let shelfID: UUID

    private var candidates: [Notebook] {
        notebooks.filter { $0.shelfID != shelfID && !$0.isTrashed }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    EmptyStateView(
                        systemImage: "books.vertical",
                        title: "Everything's on this shelf",
                        message: "All your notebooks are already here. Create a new one to add more."
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 24)],
                            spacing: 24
                        ) {
                            ForEach(candidates) { notebook in
                                cell(notebook)
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.color)
            .navigationTitle("Add books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func cell(_ notebook: Notebook) -> some View {
        Button {
            services.repository.assign(notebook, toShelf: shelfID)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    NotebookCoverView(
                        title: notebook.title,
                        coverColor: ThemeColor(hex: notebook.coverColorHex) ?? theme.accent
                    )
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                    Image(systemName: "plus.circle.fill")
                        .font(.dsTitle3)
                        .foregroundStyle(theme.accent.color)
                        .background(Circle().fill(.white))
                        .padding(8)
                }
                Text(notebook.title)
                    .font(.dsCaption).foregroundStyle(theme.ink.color).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
