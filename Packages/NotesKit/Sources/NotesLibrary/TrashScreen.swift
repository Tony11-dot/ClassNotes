import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// Recently deleted notebooks, with the ink still on disk.
///
/// The point of this screen is that deleting is not the end of the story. A
/// notebook stays here for `TrashPolicy.retention` and can be put straight back;
/// only "Delete Now" and the launch-time purge actually destroy anything.
public struct TrashScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Query private var allNotebooks: [Notebook]

    @State private var confirmEmpty = false
    @State private var purgeTarget: Notebook?
    /// True when this is one of the library's own tabs rather than a sheet —
    /// there's nothing to dismiss back to, so the "Done" button doesn't apply.
    private let isTab: Bool

    public init(isTab: Bool = false) {
        self.isTab = isTab
    }

    private var trashed: [Notebook] {
        allNotebooks
            .filter(\.isTrashed)
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if trashed.isEmpty {
                    EmptyStateView(
                        systemImage: "trash",
                        title: "Nothing deleted",
                        message: "Notebooks you delete wait here for 30 days before they're gone for good."
                    )
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.color)
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty", role: .destructive) { confirmEmpty = true }
                        .disabled(trashed.isEmpty)
                }
            }
            .confirmationDialog(
                trashed.count == 1
                    ? "Permanently delete 1 notebook? This can't be undone."
                    : "Permanently delete \(trashed.count) notebooks? This can't be undone.",
                isPresented: $confirmEmpty,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    Task { try? await services.repository.emptyTrash() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Permanently delete “\(purgeTarget?.title ?? "")”? This can't be undone.",
                isPresented: purgeBinding,
                titleVisibility: .visible
            ) {
                Button("Delete Now", role: .destructive) {
                    if let target = purgeTarget {
                        Task { try? await services.repository.purge(target) }
                    }
                    purgeTarget = nil
                }
                Button("Cancel", role: .cancel) { purgeTarget = nil }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(trashed) { notebook in
                    row(notebook)
                }
            } footer: {
                Text("Notebooks are deleted for good 30 days after you delete them.")
                    .font(.dsCaption)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.surface.color)
    }

    private func row(_ notebook: Notebook) -> some View {
        HStack(spacing: 12) {
            NotebookCoverTile(notebook: notebook)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(notebook.title)
                    .font(.dsSubheadline.weight(.medium))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Text(TrashPolicy.expiryLabel(deletedAt: notebook.deletedAt))
                    .font(.dsCaption)
                    .foregroundStyle(theme.inkSecondary.color)
            }
            Spacer()
            Button("Restore") {
                try? services.repository.restore(notebook)
            }
            .font(.dsFootnote.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent.color)
            // A label in a list row is a few points tall on its own; without a
            // real box around it the tap lands on the row instead of the button.
            .frame(minWidth: 60, minHeight: 44)
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                purgeTarget = notebook
            } label: {
                Label("Delete Now", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                try? services.repository.restore(notebook)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(theme.accent.color)
        }
    }

    private var purgeBinding: Binding<Bool> {
        Binding(
            get: { purgeTarget != nil },
            set: { if !$0 { purgeTarget = nil } }
        )
    }
}
