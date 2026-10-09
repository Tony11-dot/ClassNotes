import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// A notebook's tags: what it has (tap to remove), a field to add one, and the
/// tags already used elsewhere in the library so the same word is reused
/// rather than retyped slightly differently.
struct NotebookTagsSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let notebook: Notebook
    /// Every tag in the library.
    let suggestions: [String]

    @State private var tags: [String] = []
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var unused: [String] {
        suggestions.filter { !NotebookTags.contains($0, in: tags) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if tags.isEmpty {
                        Text("No tags yet. Add a word you'd look for it by: a subject, a term, \"exam\".")
                            .font(.dsFootnote)
                            .foregroundStyle(theme.inkSecondary.color)
                    } else {
                        chips(tags, systemImage: "xmark.circle.fill", label: { "Remove tag \($0)" }, action: { tag in
                            tags = NotebookTags.removing(tag, from: tags)
                        })
                    }
                } header: {
                    Text("Tags")
                }
                Section {
                    HStack {
                        TextField("Add a tag", text: $draft)
                            .focused($typing)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit(addDraft)
                        Button("Add", action: addDraft)
                            .disabled(NotebookTags.normalised(draft) == nil)
                    }
                }
                if !unused.isEmpty {
                    Section("Used in your library") {
                        chips(unused, systemImage: "plus.circle.fill", label: { "Add tag \($0)" }, action: { tag in
                            tags = NotebookTags.adding(tag, to: tags)
                        })
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle(notebook.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        addDraft()
                        services.repository.setTags(tags, for: notebook)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { tags = notebook.tags }
    }

    private func addDraft() {
        guard NotebookTags.normalised(draft) != nil else { return }
        tags = NotebookTags.adding(draft, to: tags)
        draft = ""
    }

    private func chips(
        _ items: [String], systemImage: String, label: @escaping (String) -> String,
        action: @escaping (String) -> Void
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)], spacing: 8) {
            ForEach(items, id: \.self) { tag in
                Button {
                    action(tag)
                } label: {
                    HStack(spacing: 4) {
                        Text("#" + tag).lineLimit(1)
                        Image(systemName: systemImage).foregroundStyle(theme.inkSecondary.color)
                    }
                    .font(.dsSubheadline.weight(.medium))
                    .foregroundStyle(theme.ink.color)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(theme.surfaceRaised.color, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(tag))
            }
        }
        .padding(.vertical, 4)
    }
}
