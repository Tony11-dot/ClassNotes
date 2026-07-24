import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// Full custom-theme editor (premium): rename, per-token override with a
/// palette grid AND a color wheel, hex entry, opacity — plus a live preview.
struct ThemeEditorScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var spec: ThemeSpec
    @State private var editingToken: ThemeToken?
    @State private var saveError = false

    init(spec: ThemeSpec) {
        self._spec = State(initialValue: spec)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Theme name", text: $spec.displayName)
                }
                Section("Preview") {
                    preview
                }
                Section("Tokens") {
                    ForEach(ThemeToken.allCases) { token in
                        tokenRow(token)
                    }
                }
                Section {
                    Toggle("Dark theme", isOn: $spec.isDark)
                } footer: {
                    Text("Controls the status bar and system appearance while this theme is active.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("Edit Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .sheet(item: $editingToken) { token in
            TokenColorEditor(
                tokenName: token.displayName,
                color: Binding(
                    get: { spec.color(for: token) },
                    set: { spec.setColor($0, for: token) }
                )
            )
            .presentationDetents([.medium, .large])
        }
        .alert("Couldn't save theme", isPresented: $saveError) {
            Button("OK") {}
        }
    }

    private var preview: some View {
        HStack(spacing: 14) {
            ThemeSwatchView(spec: spec)
            ZStack {
                PageTemplateView(template: .ruled)
                RoundedRectangle(cornerRadius: 2)
                    .fill(spec.accent.color)
                    .frame(width: 40, height: 4)
                    .rotationEffect(.degrees(-8))
            }
            .environment(\.theme, spec)
            .frame(width: 66, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(spec.separator.color, lineWidth: 0.5)
            )
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func tokenRow(_ token: ThemeToken) -> some View {
        Button {
            editingToken = token
        } label: {
            HStack {
                Text(token.displayName)
                    .foregroundStyle(theme.ink.color)
                Spacer()
                Text(spec.color(for: token).hexString)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.inkSecondary.color)
                swatchCircle(spec.color(for: token))
            }
        }
        .buttonStyle(.plain)
    }

    private func swatchCircle(_ color: ThemeColor) -> some View {
        Circle()
            .fill(color.color)
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(theme.separator.color, lineWidth: 0.5))
    }

    private func save() {
        do {
            try services.themeService.updateCustomTheme(spec)
            dismiss()
        } catch {
            saveError = true
        }
    }
}

/// One token's color: preset palette grid, system color wheel, hex field,
/// opacity slider. All routes end in the same `ThemeColor` binding.
struct TokenColorEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let tokenName: String
    @Binding var color: ThemeColor

    @State private var hexField = ""

    /// Palette grid: every preset accent + key neutrals from the presets.
    private var paletteGrid: [ThemeColor] {
        var seen = Set<String>()
        var colors: [ThemeColor] = []
        for preset in ThemePreset.allCases {
            let spec = preset.spec
            for candidate in [spec.accent, spec.surface, spec.paper, spec.ink] {
                let hex = candidate.hexString
                if seen.insert(hex).inserted {
                    colors.append(candidate)
                }
            }
        }
        return colors
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Palette")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.inkSecondary.color)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 34, maximum: 40), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(paletteGrid.map(\.hexString), id: \.self) { hex in
                            paletteCell(hex)
                        }
                    }

                    Divider()

                    ColorPicker("Color wheel", selection: wheelBinding, supportsOpacity: true)
                        .foregroundStyle(theme.ink.color)

                    HStack {
                        Text("Hex")
                            .foregroundStyle(theme.ink.color)
                        TextField("#RRGGBB", text: $hexField)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onSubmit(applyHex)
                        Button("Apply", action: applyHex)
                            .buttonStyle(.glass)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Opacity — \(Int((color.alpha * 100).rounded()))%")
                            .foregroundStyle(theme.ink.color)
                        Slider(value: alphaBinding, in: 0.05...1.0)
                    }
                }
                .padding(20)
            }
            .background(theme.surface.color)
            .navigationTitle(tokenName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { hexField = color.hexString }
        .onChange(of: color) { _, newValue in
            hexField = newValue.hexString
        }
    }

    private func paletteCell(_ hex: String) -> some View {
        let cellColor = ThemeColor(hex: hex) ?? color
        return Button {
            color = cellColor.withAlpha(color.alpha)
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cellColor.color)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.separator.color, lineWidth: 0.5)
                    if hex == color.withAlpha(1).hexString {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(theme.contrastingInk(on: cellColor).color)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Palette color \(hex)")
    }

    private var wheelBinding: Binding<Color> {
        Binding(
            get: { color.color },
            set: { newValue in
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                UIColor(newValue).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                color = ThemeColor(red: red, green: green, blue: blue, alpha: alpha)
            }
        )
    }

    private var alphaBinding: Binding<Double> {
        Binding(
            get: { color.alpha },
            set: { color = color.withAlpha($0) }
        )
    }

    private func applyHex() {
        if let parsed = ThemeColor(hex: hexField) {
            color = parsed.alpha == 1 ? parsed.withAlpha(color.alpha) : parsed
        }
    }
}
