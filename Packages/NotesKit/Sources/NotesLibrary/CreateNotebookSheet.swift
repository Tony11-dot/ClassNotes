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
    @State private var marginPosition: PageMargin.Position = .leading
    /// nil = auto (the theme's paper color).
    @State private var pageColorHex: String?
    @State private var creating = false

    private var coverColor: ThemeColor {
        ThemeColor(hex: coverHex) ?? theme.coverPalette.first ?? theme.accent
    }

    private var margin: PageMargin {
        PageMargin(position: marginPosition)
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
                Section("Margin") {
                    Picker("Margin", selection: $marginPosition) {
                        ForEach(PageMargin.Position.allCases) { pos in
                            Text(pos.displayName).tag(pos)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Page color") {
                    pageColorRow
                }
                Section("Preview") {
                    PageTemplateView(
                        template: template, margin: margin, paperColorHex: pageColorHex
                    )
                    .aspectRatio(
                        PageGeometry.size.width / PageGeometry.size.height, contentMode: .fit
                    )
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.separator.color, lineWidth: 0.5)
                    )
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
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

    /// "Default" (theme paper) + the theme's palette as page-color choices.
    private var pageColorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                pageSwatch(hex: nil, label: "Default") {
                    ZStack {
                        Circle().fill(theme.paperColor(tone: .neutral).color)
                        Image(systemName: "a.square")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.inkSecondary.color)
                    }
                }
                ForEach(theme.coverPalette.map(\.hexString), id: \.self) { hex in
                    pageSwatch(hex: hex, label: hex) {
                        Circle().fill(ThemeColor(hex: hex)?.color ?? theme.paperColor(tone: .neutral).color)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func pageSwatch(
        hex: String?, label: String, @ViewBuilder fill: () -> some View
    ) -> some View {
        let isSelected = pageColorHex == hex
        return Button {
            pageColorHex = hex
        } label: {
            fill()
                .frame(width: 34, height: 34)
                .overlay {
                    Circle().strokeBorder(theme.separator.color, lineWidth: 0.5)
                    if isSelected {
                        Circle().strokeBorder(theme.accent.color, lineWidth: 2.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page color \(label)")
    }

    private func create() {
        creating = true
        Task {
            defer { creating = false }
            _ = try? await services.repository.createNotebook(
                title: title,
                coverColor: coverColor,
                template: template,
                margin: margin,
                paperColorHex: pageColorHex
            )
            dismiss()
        }
    }
}
