import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

struct CreateNotebookSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var coverHex = ""
    @State private var template: PageTemplate = .ruled
    @State private var creating = false

    private var coverColor: ThemeColor {
        ThemeColor(hex: coverHex) ?? theme.coverPalette.first ?? theme.accent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Untitled", text: $title)
                }
                Section("Cover") {
                    CoverPaletteRow(palette: theme.coverPalette, selectedHex: $coverHex)
                    NotebookCoverView(
                        title: title.isEmpty ? "Untitled" : title,
                        coverColor: coverColor
                    )
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                }
                Section("First page") {
                    Picker("Template", selection: $template) {
                        ForEach(PageTemplate.allCases) { option in
                            Label(option.displayName, systemImage: option.symbolName)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(creating)
                }
            }
        }
        .onAppear {
            if coverHex.isEmpty {
                coverHex = (theme.coverPalette.first ?? theme.accent).hexString
            }
        }
    }

    private func create() {
        creating = true
        Task {
            defer { creating = false }
            _ = try? await services.repository.createNotebook(
                title: title,
                coverColor: coverColor,
                template: template
            )
            dismiss()
        }
    }
}
