import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

// The settings panels that pop out of the tool rail: pen, marker, eraser, and
// page settings. Split out of ToolRailView to keep each file focused.

// MARK: - Shared swatch grid

struct SwatchGrid: View {
    @Environment(\.theme) private var theme
    let colors: [String]
    let selected: String
    let onSelect: (ThemeColor) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 8)], spacing: 8) {
            ForEach(colors, id: \.self) { hex in
                let swatch = ThemeColor(hex: hex) ?? theme.ink
                Button {
                    onSelect(swatch)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Circle().strokeBorder(theme.separator.color, lineWidth: 0.5)
                            if selected == hex {
                                Circle().strokeBorder(theme.accent.color, lineWidth: 2.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(hex)")
            }
        }
        .frame(width: 224)
    }
}

// MARK: - Pen panel (ink type, color, thickness, beautification)

struct PenPanel: View {
    @Environment(\.theme) private var theme
    @Bindable var toolState: ToolState
    let onBeautify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pen").font(.headline).foregroundStyle(theme.ink.color)

            Picker("Ink", selection: $toolState.penInk) {
                ForEach(ToolState.PenInk.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            SwatchGrid(colors: toolState.inkPalette(theme: theme).map(\.hexString),
                       selected: toolState.currentColor(theme: theme).hexString) {
                toolState.setCurrentColor($0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Thickness — \(Int(toolState.penWidth.rounded())) pt")
                    .font(.subheadline).foregroundStyle(theme.inkSecondary.color)
                Slider(value: $toolState.penWidth, in: 1...12)
            }

            Divider()

            Toggle(isOn: $toolState.beautifyEnabled) {
                Label("Beautify handwriting", systemImage: "wand.and.stars")
                    .font(.subheadline).foregroundStyle(theme.ink.color)
            }
            if toolState.beautifyEnabled {
                FontRow(selected: $toolState.beautifyFontID)
                Button {
                    onBeautify()
                } label: {
                    Label("Beautify this page", systemImage: "text.badge.checkmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.glassProminent)
                Text("Re-typesets your handwriting into the chosen font as editable text.")
                    .font(.caption).foregroundStyle(theme.inkSecondary.color)
            }
        }
        .padding(18)
        .frame(width: 260)
        .background(theme.surfaceRaised.color)
    }
}

struct FontRow: View {
    @Environment(\.theme) private var theme
    @Binding var selected: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FontLibrary.all) { font in
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
        .frame(width: 224)
    }
}

// MARK: - Marker panel

struct MarkerPanel: View {
    @Environment(\.theme) private var theme
    @Bindable var toolState: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Marker").font(.headline).foregroundStyle(theme.ink.color)
            SwatchGrid(colors: toolState.inkPalette(theme: theme).map(\.hexString),
                       selected: toolState.currentColor(theme: theme).hexString) {
                toolState.setCurrentColor($0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Thickness — \(Int(toolState.markerWidth.rounded())) pt")
                    .font(.subheadline).foregroundStyle(theme.inkSecondary.color)
                Slider(value: $toolState.markerWidth, in: 6...30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Opacity — \(Int((toolState.markerOpacity * 100).rounded()))%")
                    .font(.subheadline).foregroundStyle(theme.inkSecondary.color)
                Slider(value: $toolState.markerOpacity, in: 0.1...0.9)
            }
        }
        .padding(18)
        .frame(width: 260)
        .background(theme.surfaceRaised.color)
    }
}

// MARK: - Eraser panel

struct EraserPanel: View {
    @Environment(\.theme) private var theme
    @Bindable var toolState: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Eraser").font(.headline).foregroundStyle(theme.ink.color)
            Picker("Mode", selection: $toolState.eraserMode) {
                ForEach(ToolState.EraserMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            if toolState.eraserMode == .pixel {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Size — \(Int(toolState.eraserWidth.rounded())) pt")
                        .font(.subheadline).foregroundStyle(theme.inkSecondary.color)
                    Slider(value: $toolState.eraserWidth, in: 6...60)
                }
            } else {
                Text("Removes a whole stroke on contact. Undo brings it back.")
                    .font(.subheadline).foregroundStyle(theme.inkSecondary.color)
            }
        }
        .padding(18)
        .frame(width: 240)
        .background(theme.surfaceRaised.color)
    }
}

// MARK: - Page settings panel (paper + margin)

struct PageSettingsPanel: View {
    @Environment(\.theme) private var theme
    let model: NotebookEditorModel

    private var pageID: UUID? { model.focusedPageID ?? model.pages.first?.id }
    private var current: PageRecord? { model.page(pageID) }
    /// Margin color choices come from the theme (no raw hex), plus "Auto".
    private var marginColors: [ThemeColor] { Array(theme.coverPalette.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Page").font(.headline).foregroundStyle(theme.ink.color)

            Text("Paper").font(.subheadline).foregroundStyle(theme.inkSecondary.color)
            HStack(spacing: 8) {
                ForEach(PageTemplate.allCases) { template in
                    paperButton(template)
                }
            }

            Divider()

            Text("Margin line").font(.subheadline).foregroundStyle(theme.inkSecondary.color)
            Picker("Margin", selection: marginPositionBinding) {
                ForEach(PageMargin.Position.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            if current?.margin.position != PageMargin.Position.none {
                marginColorRow
            }
        }
        .padding(18)
        .frame(width: 260)
        .background(theme.surfaceRaised.color)
    }

    private func paperButton(_ template: PageTemplate) -> some View {
        let isOn = current?.template == template
        return Button {
            if let pageID { Task { await model.updatePageSettings(pageID: pageID, template: template) } }
        } label: {
            Image(systemName: template.symbolName)
                .font(.system(size: 18))
                .frame(width: 44, height: 44)
                .foregroundStyle(isOn ? theme.accent.color : theme.ink.color)
                .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isOn ? theme.accent.color : theme.separator.color, lineWidth: isOn ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.displayName)
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
                    Image(systemName: "a.circle").font(.system(size: 13)).foregroundStyle(theme.ink.color)
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
