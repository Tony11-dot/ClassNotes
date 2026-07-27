import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Real-time beautification

/// The beautification panel — the switch, the writing font, the recognition
/// language, and whether every line is normalized to one size and line height.
struct BeautifyPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppServices.self) private var services

    @Bindable var toolState: ToolState
    let onBeautifyNow: () -> Void

    @State private var showFontImporter = false
    @State private var showLanguages = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(title: "Real-time beautification")

                Toggle(isOn: $toolState.beautify.isEnabled) {
                    Text("Real-time handwriting beautification")
                        .font(.dsSubheadline).foregroundStyle(theme.ink.color)
                }

                Text("Write normally. When you pause, each line is read on-device and "
                     + "re-set in your font, right where you wrote it.")
                    .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)

                Divider().overlay(theme.separator.color)

                HStack {
                    Text("Writing font").font(.dsSubheadline).foregroundStyle(theme.ink.color)
                    Spacer()
                    Text(selectedFont.displayName)
                        .font(.dsSubheadline).foregroundStyle(theme.inkSecondary.color)
                        .lineLimit(1)
                }
                FontRow(selected: $toolState.beautify.fontID, custom: services.fontStore.fonts)
                Button {
                    showFontImporter = true
                } label: {
                    Label("Add font (OTF / TTF)", systemImage: "plus")
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)

                Toggle(isOn: $toolState.beautify.dynamicBold) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dynamic Bold").font(.dsSubheadline).foregroundStyle(theme.ink.color)
                        Text("Press harder and the typeset words come out heavier.")
                            .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
                    }
                }

                Divider().overlay(theme.separator.color)

                Button {
                    showLanguages = true
                } label: {
                    HStack {
                        Text("Writing language").font(.dsSubheadline).foregroundStyle(theme.ink.color)
                        Spacer()
                        Text(BeautifyLanguage.named(toolState.beautify.language).displayName)
                            .font(.dsSubheadline).foregroundStyle(theme.inkSecondary.color)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().overlay(theme.separator.color)

                Toggle(isOn: $toolState.beautify.unifySizeAndSpacing) {
                    Text("Unify Font Size & Line Spacing")
                        .font(.dsSubheadline).foregroundStyle(theme.ink.color)
                }

                if toolState.beautify.unifySizeAndSpacing {
                    PanelSlider(
                        title: "Unify Font Size",
                        readout: "\(Int(toolState.beautify.fontSize.rounded()))",
                        value: $toolState.beautify.fontSize,
                        range: BeautifySettings.fontSizeRange,
                        step: 1,
                        showsSteppers: true
                    )
                    PanelSlider(
                        title: "Unify Line Spacing",
                        readout: String(format: "%.1f", toolState.beautify.lineSpacing),
                        value: $toolState.beautify.lineSpacing,
                        range: BeautifySettings.lineSpacingRange,
                        step: 0.1,
                        showsSteppers: true
                    )
                } else {
                    Text("Each line keeps the size you wrote it at.")
                        .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
                }

                PanelSlider(
                    title: "Settle delay",
                    readout: String(format: "%.1fs", toolState.beautify.settleDelay),
                    value: $toolState.beautify.settleDelay,
                    range: BeautifySettings.settleRange,
                    step: 0.1,
                    hint: "How long to wait after you stop writing before a line is set."
                )

                Button {
                    onBeautifyNow()
                } label: {
                    Label("Beautify this page now", systemImage: "text.badge.checkmark")
                        .font(.dsSubheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.glassProminent)
            }
            .padding(18)
        }
        .frame(width: 300)
        .frame(maxHeight: 640)
        .background(theme.surfaceRaised.color)
        .sheet(isPresented: $showLanguages) {
            LanguagePickerSheet(selection: $toolState.beautify.language)
        }
        .fileImporter(
            isPresented: $showFontImporter,
            allowedContentTypes: [UTType(filenameExtension: "otf") ?? .font, .font],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            var last: String?
            for url in urls {
                if let font = services.fontStore.importFont(from: url) { last = font.id }
            }
            // Auto-select the freshly imported face so it's ready to use.
            if let last { toolState.beautify.fontID = last }
        }
    }

    private var selectedFont: HandwritingFont {
        services.fontStore.resolve(id: toolState.beautify.fontID)
            ?? FontLibrary.font(id: toolState.beautify.fontID)
    }
}

/// The writing-language list behind the beautification panel.
struct LanguagePickerSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String

    var body: some View {
        NavigationStack {
            List(BeautifyLanguage.all) { language in
                Button {
                    selection = language.code
                    dismiss()
                } label: {
                    HStack {
                        Text(language.displayName).foregroundStyle(theme.ink.color)
                        Spacer()
                        if selection == language.code {
                            Image(systemName: "checkmark").foregroundStyle(theme.accent.color)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Writing language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The horizontal font picker shared by beautification and text boxes.
struct FontRow: View {
    @Environment(\.theme) private var theme
    @Binding var selected: String
    /// User-uploaded faces, shown after the curated pack.
    var custom: [HandwritingFont] = []

    private var allFonts: [HandwritingFont] { FontLibrary.all + custom }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allFonts) { font in
                    Button {
                        selected = font.id
                    } label: {
                        Text("Aa")
                            .font(.custom(font.fontName, size: 20))
                            .foregroundStyle(theme.ink.color)
                            .frame(width: 52, height: 44)
                            .background(theme.surface.color,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(selected == font.id ? theme.accent.color : theme.separator.color,
                                                  lineWidth: selected == font.id ? 2 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(font.displayName)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(width: 252)
    }
}

// MARK: - Text boxes

/// Styling for the text boxes the text tool drops on the page.
struct TextBoxPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppServices.self) private var services
    @Bindable var toolState: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: "Text")
            Text("Tap anywhere on the page to drop a text box, then type.")
                .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)

            Text("Font").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
            FontRow(selected: $toolState.textFontID, custom: services.fontStore.fonts)

            PanelSlider(
                title: "Size",
                readout: "\(Int(toolState.textSize.rounded()))",
                value: $toolState.textSize,
                range: 10...72,
                step: 1,
                showsSteppers: true
            )

            Text("Color").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
            ColorSwatchRow(
                swatches: toolState.inkPalette(theme: theme).map(\.hexString),
                selection: $toolState.textColorHex,
                includesAuto: true
            )
        }
        .padding(18)
        .frame(width: 288)
        .background(theme.surfaceRaised.color)
    }
}

// MARK: - Page settings panel (paper, geometry, rules)

struct PageSettingsPanel: View {
    @Environment(\.theme) private var theme
    let model: NotebookEditorModel

    private var pageID: UUID? { model.focusedPageID ?? model.pages.first?.id }
    private var current: PageRecord? { model.page(pageID) }
    /// Margin color choices come from the theme (no raw hex), plus "Auto".
    private var marginColors: [ThemeColor] { Array(theme.coverPalette.prefix(5)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(title: "Page")

                Text("Paper").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PageTemplate.allCases) { template in
                            paperButton(template)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if current?.template.honorsLineSpacing == true {
                    PanelSlider(
                        title: "Spacing",
                        readout: "\(current?.lineSpacingSteps ?? PageLineSpacing.default)",
                        value: spacingBinding,
                        range: pageSpacingRange,
                        step: 1
                    )
                }

                Text("Line color").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
                LineColorRow(selection: lineColorBinding)

                Text("Paper color").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
                PaperSwatchRow(selection: paperColorBinding)

                Divider().overlay(theme.separator.color)

                Text("Margin line").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
                Picker("Margin", selection: marginPositionBinding) {
                    ForEach(PageMargin.Position.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                if current?.margin.position != PageMargin.Position.none {
                    marginColorRow
                }

                Divider().overlay(theme.separator.color)

                Button {
                    if let pageID { Task { await model.applyStyleToAllPages(from: pageID) } }
                } label: {
                    Label("Apply to every page", systemImage: "square.on.square")
                        .font(.dsSubheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glass)
            }
            .padding(18)
        }
        .frame(width: 288)
        .frame(maxHeight: 600)
        .background(theme.surfaceRaised.color)
    }

    private func paperButton(_ template: PageTemplate) -> some View {
        let isOn = current?.template == template
        return Button {
            if let pageID { Task { await model.updatePageSettings(pageID: pageID, template: template) } }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: template.symbolName)
                    .font(.dsSystem(size: 17))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(isOn ? theme.accent.color : theme.ink.color)
                    .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isOn ? theme.accent.color : theme.separator.color, lineWidth: isOn ? 2 : 0.5))
                Text(template.displayName)
                    .font(.dsCaption2)
                    .foregroundStyle(isOn ? theme.accent.color : theme.inkSecondary.color)
            }
            .frame(width: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.displayName)
    }

    private var spacingBinding: Binding<Double> {
        Binding(
            get: { Double(current?.lineSpacingSteps ?? PageLineSpacing.default) },
            set: { value in
                guard let pageID else { return }
                Task { await model.updatePageSettings(pageID: pageID, lineSpacingSteps: Int(value.rounded())) }
            }
        )
    }

    private var lineColorBinding: Binding<String?> {
        Binding(
            get: { current?.lineColorHex },
            set: { hex in
                guard let pageID else { return }
                Task {
                    await model.updatePageSettings(
                        pageID: pageID, lineColorHex: hex, clearLineColor: hex == nil
                    )
                }
            }
        )
    }

    private var paperColorBinding: Binding<String?> {
        Binding(
            get: { current?.paperColorHex },
            set: { hex in
                guard let pageID else { return }
                Task {
                    await model.updatePageSettings(
                        pageID: pageID, paperColorHex: hex, clearPaperColor: hex == nil
                    )
                }
            }
        )
    }

    private var marginPositionBinding: Binding<PageMargin.Position> {
        Binding(
            get: { current?.margin.position ?? .leading },
            set: { pos in
                guard let pageID else { return }
                var margin = current?.margin ?? .default
                margin.position = pos
                Task { await model.updatePageSettings(pageID: pageID, margin: margin) }
            }
        )
    }

    private var marginColorRow: some View {
        HStack(spacing: 8) {
            marginSwatch(nil)                       // Auto (paper-derived)
            ForEach(marginColors, id: \.hexString) { color in
                marginSwatch(color.hexString)
            }
        }
    }

    private func marginSwatch(_ hex: String?) -> some View {
        let isOn = (current?.margin.colorHex ?? nil) == hex
        let fill: Color = hex.flatMap { ThemeColor(hex: $0)?.color } ?? theme.separator.color
        return Button {
            guard let pageID else { return }
            var margin = current?.margin ?? .default
            margin.colorHex = hex
            Task { await model.updatePageSettings(pageID: pageID, margin: margin) }
        } label: {
            ZStack {
                Circle().fill(fill).frame(width: 28, height: 28)
                if hex == nil {
                    Image(systemName: "a.circle").font(.dsSystem(size: 13)).foregroundStyle(theme.ink.color)
                }
            }
            .overlay {
                Circle().strokeBorder(isOn ? theme.accent.color : theme.separator.color, lineWidth: isOn ? 2.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex == nil ? "Auto margin color" : "Margin color")
    }
}
