import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// Per-page settings: paper template (incl. dotted/dashed rules), margin line,
/// and page color. Applies live so the page updates behind the sheet. Used from
/// the editor's More menu and the page manager.
struct PageSettingsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let page: PageRecord
    /// (template, margin, paperColorHex) — `paperColorHex == nil` means auto.
    let onApply: (PageTemplate, PageMargin, String?) -> Void

    @State private var template: PageTemplate
    @State private var marginPosition: PageMargin.Position
    @State private var paperColorHex: String?

    init(page: PageRecord, onApply: @escaping (PageTemplate, PageMargin, String?) -> Void) {
        self.page = page
        self.onApply = onApply
        _template = State(initialValue: page.template)
        _marginPosition = State(initialValue: page.margin.position)
        _paperColorHex = State(initialValue: page.paperColorHex)
    }

    private var currentMargin: PageMargin {
        PageMargin(position: marginPosition, colorHex: page.margin.colorHex, offset: page.margin.offset)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    PageTemplateView(template: template, margin: currentMargin, paperColorHex: paperColorHex)
                        .aspectRatio(PageGeometry.size.width / PageGeometry.size.height, contentMode: .fit)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(theme.separator.color, lineWidth: 0.5)
                        )
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                Section("Paper") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(PageTemplate.allCases) { option in
                            templateChip(option)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Margin line") {
                    Picker("Margin", selection: $marginPosition) {
                        ForEach(PageMargin.Position.allCases) { pos in
                            Text(pos.displayName).tag(pos)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Page color") {
                    PaperSwatchRow(selection: $paperColorHex)
                }
            }
            .navigationTitle("Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: template) { _, _ in apply() }
            .onChange(of: marginPosition) { _, _ in apply() }
            .onChange(of: paperColorHex) { _, _ in apply() }
        }
    }

    private func apply() {
        onApply(template, currentMargin, paperColorHex)
    }

    private func templateChip(_ option: PageTemplate) -> some View {
        let selected = option == template
        return Button {
            template = option
        } label: {
            VStack(spacing: 6) {
                PageTemplateView(template: option, margin: nil, paperColorHex: paperColorHex)
                    .aspectRatio(0.78, contentMode: .fit)
                    .frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(selected ? theme.accent.color : theme.separator.color,
                                          lineWidth: selected ? 2 : 0.5)
                    )
                Text(option.displayName)
                    .font(.caption2)
                    .foregroundStyle(selected ? theme.accent.color : theme.inkSecondary.color)
            }
        }
        .buttonStyle(.plain)
    }
}
// PaperSwatchRow lives in NotesDesignSystem so both the editor and the library
// (New Notebook) can share it without violating the NotesEditor import rule.
