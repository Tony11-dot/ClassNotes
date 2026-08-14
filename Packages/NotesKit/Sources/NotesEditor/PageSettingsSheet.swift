import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// Per-page settings: paper template, rule spacing, line and paper colors, the
/// margin rule, and the page's own size and direction. Applies live so the page
/// updates behind the sheet. Used from the editor's More menu.
struct PageSettingsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let page: PageRecord
    /// Which page this is, 1-based — so it's obvious what the sheet is editing.
    let index: Int?
    let onApply: (PageStyle) -> Void
    let onApplyToAll: () -> Void

    @State private var style: PageStyle
    @State private var appliedToAll = false

    init(
        page: PageRecord,
        index: Int? = nil,
        onApply: @escaping (PageStyle) -> Void,
        onApplyToAll: @escaping () -> Void = {}
    ) {
        self.page = page
        self.index = index
        self.onApply = onApply
        self.onApplyToAll = onApplyToAll
        _style = State(initialValue: page.style)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // A notebook can be dozens of pages long and these settings
                    // are per page. Saying which one stops "nothing changed" from
                    // meaning "you were changing a different page".
                    Button {
                        onApplyToAll()
                        appliedToAll = true
                    } label: {
                        Label(
                            appliedToAll ? "Applied to every page" : "Apply to every page",
                            systemImage: appliedToAll ? "checkmark.circle.fill" : "square.on.square"
                        )
                        .foregroundStyle(theme.accent.color)
                    }
                    .disabled(appliedToAll)
                } header: {
                    Text(index.map { "Page \($0)" } ?? "This page")
                } footer: {
                    Text("These settings change this page only, unless you apply them to every page.")
                        .font(.dsCaption)
                }

                Section("Preview") {
                    PageTemplateView(style: style)
                        .aspectRatio(PageTemplateView.aspectRatio(of: style), contentMode: .fit)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(theme.separator.color, lineWidth: 0.5)
                        )
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                ForEach(PageTemplate.Family.allCases) { family in
                    Section(family.displayName) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                            spacing: 10
                        ) {
                            ForEach(family.templates) { option in
                                templateChip(option)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if style.template.honorsLineSpacing {
                    Section("Spacing") {
                        Stepper(
                            value: $style.lineSpacingSteps,
                            in: PageLineSpacing.range
                        ) {
                            Text("Line spacing — \(style.lineSpacingSteps)")
                        }
                    }
                }

                Section("Line color") {
                    LineColorRow(selection: $style.lineColorHex)
                }

                Section("Paper color") {
                    PaperSwatchRow(selection: $style.paperColorHex)
                }

                Section("Margin line") {
                    Picker("Margin", selection: marginPositionBinding) {
                        ForEach(PageMargin.Position.allCases) { pos in
                            Text(pos.displayName).tag(pos)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Paper size") {
                    Picker("Direction", selection: $style.orientation) {
                        ForEach(PageOrientation.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Size", selection: $style.pageSize) {
                        ForEach(PageSize.notebookChoices) { Text($0.displayName).tag($0) }
                    }
                    Text("Changing the size of a page that already has ink keeps the "
                         + "strokes where they are; they may sit differently on the new paper.")
                        .font(.dsCaption)
                        .foregroundStyle(theme.inkSecondary.color)
                }
            }
            .navigationTitle("Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: style) { _, updated in
                appliedToAll = false
                onApply(updated)
            }
        }
    }

    private var marginPositionBinding: Binding<PageMargin.Position> {
        Binding(
            get: { style.margin.position },
            set: { style.margin.position = $0 }
        )
    }

    private func templateChip(_ option: PageTemplate) -> some View {
        var preview = style
        preview.template = option
        preview.margin = PageMargin(position: .none)
        let selected = option == style.template
        return Button {
            style.template = option
        } label: {
            VStack(spacing: 6) {
                PageTemplateView(style: preview)
                    .aspectRatio(0.78, contentMode: .fit)
                    .frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(selected ? theme.accent.color : theme.separator.color,
                                          lineWidth: selected ? 2 : 0.5)
                    )
                Text(option.displayName)
                    .font(.dsCaption2)
                    .foregroundStyle(selected ? theme.accent.color : theme.inkSecondary.color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
