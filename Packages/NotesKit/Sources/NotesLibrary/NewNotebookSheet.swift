import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

/// The New Notebook screen.
///
/// ONE scroll, top to bottom: the Cancel / title / Create bar is the only pinned
/// part; below it the cover and paper previews (two big rectangles, side by side),
/// then the title / cover / direction / size settings, then every template, then
/// paper colour, line colour and rule spacing. Everything previews live, so what
/// you see is what gets created.
///
/// Why one scroll: with the settings pinned at the top and the colour pickers
/// pinned at the bottom, a short window squeezed both — labels wrapped onto two
/// lines and the colour rows were cut off with no way to reach them. Now every
/// section is full width, every label is one line, and the whole page moves.
struct NewNotebookSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) var theme
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [Notebook]

    /// When created from inside a shelf, the new notebook is filed there.
    let shelfID: UUID?
    /// A board has no pages, so the sheet hides paper size and the cover switch.
    let kind: NotebookKind
    /// Called with the notebook once it exists, so the library can open it.
    let onCreated: (Notebook) -> Void

    @State var title = ""
    @State var coverHex = ""
    @State var coverDesign: CoverDesign = .default
    @State var showsCover = true
    @State var style = PageStyle(template: .ruled, pageSize: .a4)
    @State private var creating = false
    @State var showCoverPicker = false

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

    var coverColor: ThemeColor {
        ThemeColor(hex: coverHex) ?? theme.coverPalette.first ?? theme.accent
    }

    /// Trashed notebooks don't count. Otherwise deleting five books and making a
    /// new one names it "Untitled Notebook 6" against a library showing one.
    private var liveCount: Int { existing.filter { !$0.isTrashed }.count }

    private var placeholderTitle: String {
        kind == .whiteboard
            ? "Untitled Whiteboard \(liveCount + 1)"
            : "Untitled Notebook \(liveCount + 1)"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(theme.separator.color)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    previewRow
                    detailsCard
                    if kind != .whiteboard { geometryCard }
                    templateSection
                    colorSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
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

    var previewTitle: String {
        title.isEmpty ? placeholderTitle : title
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(.dsHeadline)
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(theme.surfaceRaised.color, in: Capsule())
                .buttonStyle(.plain)

            Spacer()
            Text(kind == .whiteboard ? "New Whiteboard" : "New Notebook")
                .font(.dsTitle3.weight(.bold))
                .foregroundStyle(theme.ink.color)
            Spacer()

            Button {
                create()
            } label: {
                Text("Create")
                    .font(.dsHeadline)
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

    private var detailsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Title")
                    .font(.dsHeadline)
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 68, alignment: .leading)
                TextField(placeholderTitle, text: $title)
                    .font(.dsTitle3)
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            if kind != .whiteboard {
                Divider().overlay(theme.separator.color).padding(.leading, 18)
                HStack {
                    Text("Cover")
                        .font(.dsHeadline)
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
                .font(.dsHeadline)
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            content()
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(theme.ink.color)
                .fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }

    // MARK: - Templates

    /// Inline in the page's own scroll — a nested ScrollView here was the reason
    /// only the middle of the screen moved.
    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(PageTemplate.Family.allCases) { family in
                VStack(alignment: .leading, spacing: 10) {
                    Text(family.displayName)
                        .font(.dsHeadline)
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 108, maximum: 168), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(family.templates) { template in
                            templateChip(template)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                            .font(.dsSystem(size: 13, weight: .bold))
                            .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                            .frame(width: 26, height: 26)
                            .background(theme.accent.color, in: Circle())
                            .padding(.bottom, 12)
                    }
                }
                .shadow(color: .black.opacity(isSelected ? 0.14 : 0.06), radius: 8, y: 4)
                Text(template.displayName)
                    .font(.dsSubheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.ink.color : theme.inkSecondary.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Colours + spacing

    /// Full-width rows, stacked. Side by side, each colour row was squeezed to a
    /// third of the window and its swatches ran off the edge with nothing to say so.
    private var colorSection: some View {
        VStack(spacing: 0) {
            settingRow("Paper colour") {
                PaperSwatchRow(selection: $style.paperColorHex)
            }
            Divider().overlay(theme.separator.color).padding(.leading, 18)
            settingRow("Line colour") {
                LineColorRow(selection: $style.lineColorHex)
            }
            Divider().overlay(theme.separator.color).padding(.leading, 18)
            settingRow("Line spacing", trailing: "\(style.lineSpacingSteps)") {
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
        }
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// A one-line label with its control on the row below, full width.
    private func settingRow<Content: View>(
        _ label: String, trailing: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.dsSubheadline.weight(.semibold))
                    .foregroundStyle(theme.inkSecondary.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.dsSubheadline.monospacedDigit())
                        .foregroundStyle(theme.ink.color)
                }
            }
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
