import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// The New Notebook screen.
///
/// Layout, top to bottom: a Cancel / title / Create bar; a row with the live cover
/// and paper previews beside the title, cover switch, direction and size; then
/// every template, grouped; then paper colour, line colour and rule spacing along
/// the bottom. Everything previews live, so what you see is what gets created.
struct NewNotebookSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [Notebook]

    /// When created from inside a shelf, the new notebook is filed there.
    let shelfID: UUID?
    /// A board has no pages, so the sheet hides paper size and the cover switch.
    let kind: NotebookKind
    /// Called with the notebook once it exists, so the library can open it.
    let onCreated: (Notebook) -> Void

    @State private var title = ""
    @State private var coverHex = ""
    @State private var coverDesign: CoverDesign = .default
    @State private var showsCover = true
    @State private var style = PageStyle(template: .ruled, pageSize: .a4)
    @State private var creating = false
    @State private var showCoverPicker = false

    init(
        shelfID: UUID? = nil,
        kind: NotebookKind = .notebook,
        onCreated: @escaping (Notebook) -> Void = { _ in }
    ) {
        self.shelfID = shelfID
        self.kind = kind
        self.onCreated = onCreated
        // A board is one big landscape canvas; a notebook starts on A4 portrait.
        _style = State(initialValue: kind == .whiteboard
            ? PageStyle(template: .grid, margin: PageMargin(position: .none),
                        pageSize: .whiteboard, orientation: .landscape)
            : PageStyle(template: .ruled, pageSize: .a4))
    }

    private var coverColor: ThemeColor {
        ThemeColor(hex: coverHex) ?? theme.coverPalette.first ?? theme.accent
    }

    private var placeholderTitle: String {
        kind == .whiteboard
            ? "Untitled Whiteboard \(existing.count + 1)"
            : "Untitled Notebook \(existing.count + 1)"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            summaryRow
            Divider().overlay(theme.separator.color)
            templateGallery
            Divider().overlay(theme.separator.color)
            bottomBar
        }
        .background(theme.surface.color)
        .onAppear {
            if coverHex.isEmpty {
                coverHex = (theme.coverPalette.first ?? theme.accent).hexString
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            CoverDesignPicker(design: $coverDesign, colorHex: $coverHex, title: previewTitle)
        }
    }

    private var previewTitle: String {
        title.isEmpty ? placeholderTitle : title
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(.headline)
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(theme.surfaceRaised.color, in: Capsule())
                .buttonStyle(.plain)

            Spacer()
            Text(kind == .whiteboard ? "New Whiteboard" : "New Notebook")
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.ink.color)
            Spacer()

            Button {
                create()
            } label: {
                Text("Create")
                    .font(.headline)
                    .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                    .padding(.horizontal, 26).padding(.vertical, 12)
                    .background(theme.accent.color, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(creating)
            .opacity(creating ? 0.6 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Summary row (cover · paper · settings)

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 18) {
            if kind != .whiteboard {
                coverPreview
            }
            paperPreview
            VStack(spacing: 14) {
                detailsCard
                if kind != .whiteboard {
                    geometryCard
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
    }

    private var coverPreview: some View {
        Button {
            showCoverPicker = true
        } label: {
            VStack(spacing: 8) {
                NotebookCoverView(
                    title: previewTitle, coverColor: coverColor,
                    design: coverDesign, showsTitle: showsCover
                )
                .frame(width: 132)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                Text(coverDesign.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
                Text("Cover")
                    .font(.caption)
                    .foregroundStyle(theme.inkSecondary.color)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cover: \(coverDesign.displayName). Tap to change.")
    }

    private var paperPreview: some View {
        VStack(spacing: 8) {
            PageTemplateView(style: style)
                .aspectRatio(PageTemplateView.aspectRatio(of: style), contentMode: .fit)
                .frame(height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.separator.color, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            Text(style.template.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.ink.color)
            Text("Template")
                .font(.caption)
                .foregroundStyle(theme.inkSecondary.color)
        }
        .padding(14)
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Title")
                    .font(.headline)
                    .foregroundStyle(theme.ink.color)
                    .frame(width: 92, alignment: .leading)
                TextField(placeholderTitle, text: $title)
                    .font(.title3)
                    .foregroundStyle(theme.ink.color)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            if kind != .whiteboard {
                Divider().overlay(theme.separator.color).padding(.leading, 18)
                HStack {
                    Text("Cover")
                        .font(.headline)
                        .foregroundStyle(theme.ink.color)
                    Spacer()
                    Toggle("", isOn: $showsCover).labelsHidden()
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var geometryCard: some View {
        VStack(spacing: 0) {
            pickerRow("Direction") {
                Picker("Direction", selection: $style.orientation) {
                    ForEach(PageOrientation.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Divider().overlay(theme.separator.color).padding(.leading, 18)
            pickerRow("Size") {
                Picker("Size", selection: $style.pageSize) {
                    ForEach(PageSize.notebookChoices) { Text($0.displayName).tag($0) }
                }
            }
        }
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pickerRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .font(.headline)
                .foregroundStyle(theme.ink.color)
            Spacer()
            content()
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(theme.ink.color)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }

    // MARK: - Templates

    private var templateGallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(PageTemplate.Family.allCases) { family in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(family.displayName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(theme.ink.color)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 118, maximum: 190), spacing: 22)],
                            spacing: 20
                        ) {
                            ForEach(family.templates) { template in
                                templateChip(template)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private func templateChip(_ template: PageTemplate) -> some View {
        var preview = style
        preview.template = template
        let isSelected = style.template == template
        return Button {
            style.template = template
        } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .bottom) {
                    PageTemplateView(style: preview)
                        .aspectRatio(PageTemplateView.aspectRatio(of: preview), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    isSelected ? theme.accent.color : theme.separator.color,
                                    lineWidth: isSelected ? 2.5 : 0.5
                                )
                        )
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                            .frame(width: 26, height: 26)
                            .background(theme.accent.color, in: Circle())
                            .padding(.bottom, 12)
                    }
                }
                .shadow(color: .black.opacity(isSelected ? 0.14 : 0.06), radius: 8, y: 4)
                Text(template.displayName)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.ink.color : theme.inkSecondary.color)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Bottom bar (colors + spacing)

    private var bottomBar: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paper Color")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.inkSecondary.color)
                PaperSwatchRow(selection: $style.paperColorHex)
            }
            Divider().frame(height: 52).overlay(theme.separator.color)
            VStack(alignment: .leading, spacing: 6) {
                Text("Line Color")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.inkSecondary.color)
                LineColorRow(selection: $style.lineColorHex)
            }
            Divider().frame(height: 52).overlay(theme.separator.color)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Spacing")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.inkSecondary.color)
                    Spacer()
                    Text("\(style.lineSpacingSteps)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(theme.ink.color)
                }
                Slider(
                    value: Binding(
                        get: { Double(style.lineSpacingSteps) },
                        set: { style.lineSpacingSteps = Int($0.rounded()) }
                    ),
                    in: Double(PageLineSpacing.range.lowerBound)...Double(PageLineSpacing.range.upperBound),
                    step: 1
                )
                .disabled(!style.template.honorsLineSpacing)
                .opacity(style.template.honorsLineSpacing ? 1 : 0.4)
            }
            .frame(maxWidth: 260)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.surface.color)
    }

    // MARK: - Create

    private func create() {
        creating = true
        Task {
            defer { creating = false }
            // A board's margin rule would be meaningless on an endless canvas.
            var finalStyle = style
            if kind == .whiteboard { finalStyle.margin = PageMargin(position: .none) }
            if let notebook = try? await services.repository.create(
                title: title,
                coverColor: coverColor,
                style: finalStyle,
                kind: kind,
                coverDesign: coverDesign,
                showsCover: kind == .whiteboard ? false : showsCover,
                shelfID: shelfID
            ) {
                onCreated(notebook)
            }
            dismiss()
        }
    }
}
