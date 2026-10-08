import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// The notebook's Recently Deleted pages: everything a delete took in the last
/// `TrashPolicy.retention`, each restorable to where it was.
///
/// The Undo toast covers "oops, not that one" in the moment. This covers
/// noticing next week that the page with the worked example is gone.
struct DeletedPagesSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let model: NotebookEditorModel
    /// A page was restored — the editor jumps to it.
    let onRestore: (UUID) -> Void

    @State private var entries: [PageTrash.Entry] = []
    @State private var loaded = false
    @State private var confirmEmpty = false

    var body: some View {
        NavigationStack {
            Group {
                if loaded, entries.isEmpty {
                    ContentUnavailableView(
                        "No deleted pages",
                        systemImage: "trash",
                        description: Text("Pages you delete stay here for 30 days, so you can put them back.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(entries) { entry in row(entry) }
                        } footer: {
                            Text("Deleted pages are removed for good after 30 days.")
                        }
                    }
                }
            }
            .font(.dsBody)
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete All", role: .destructive) { confirmEmpty = true }
                        .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog(
                "Delete these pages for good?",
                isPresented: $confirmEmpty,
                titleVisibility: .visible
            ) {
                Button("Delete \(entries.count == 1 ? "1 Page" : "\(entries.count) Pages")", role: .destructive) {
                    Task {
                        await model.purgeTrashedPages(entries.map(\.id))
                        await reload()
                    }
                }
            } message: {
                Text("Their ink, photos and voice notes can't be brought back after this.")
            }
            .task { await reload() }
        }
    }

    private func row(_ entry: PageTrash.Entry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.page.template.symbolName)
                .font(.dsTitle3)
                .foregroundStyle(theme.inkSecondary.color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.page.isCover ? "Cover" : "Page \(entry.index + 1)")
                    .font(.dsBody.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
                Text(detail(entry))
                    .font(.dsCaption)
                    .foregroundStyle(theme.inkSecondary.color)
            }
            Spacer()
            Button("Restore") {
                Task {
                    await model.restorePage(entry.id)
                    onRestore(entry.id)
                }
            }
            .font(.dsSubheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Restore") {
            Task {
                await model.restorePage(entry.id)
                onRestore(entry.id)
            }
        }
    }

    private func detail(_ entry: PageTrash.Entry) -> String {
        let deleted = entry.deletedAt.formatted(.relative(presentation: .named))
        return "Deleted \(deleted) · \(TrashPolicy.expiryLabel(deletedAt: entry.deletedAt))"
    }

    private func reload() async {
        entries = await model.trashedPages()
        loaded = true
    }
}
