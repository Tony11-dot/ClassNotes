import ClassMateTheme
import NotesDesignSystem
import NotesPaywall
import NotesServices
import SwiftUI
import UniformTypeIdentifiers

/// Settings: theme gallery with live swatches, paper tone, custom themes
/// (premium), premium status, and the DEBUG entitlement toggle.
public struct SettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var editingTheme: ThemeSpec?
    @State private var showPaywall = false
    @State private var importingJSON = false
    @State private var exportPayload: ThemeJSONFile?
    @State private var themeError: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                presetSection(title: "Light themes", presets: ThemePreset.lightFamily, includeSystem: true)
                presetSection(title: "Dark themes", presets: ThemePreset.darkFamily, includeSystem: false)
                customThemesSection
                paperSection
                premiumSection
                #if DEBUG
                debugSection
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $editingTheme) { spec in
            ThemeEditorScreen(spec: spec)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .fileImporter(
            isPresented: $importingJSON,
            allowedContentTypes: [.json]
        ) { result in
            importThemeJSON(result)
        }
        .fileExporter(
            isPresented: exportBinding,
            document: exportPayload,
            contentType: .json,
            defaultFilename: exportPayload?.suggestedName ?? "theme"
        ) { _ in
            exportPayload = nil
        }
        .alert("Theme error", isPresented: themeErrorBinding) {
            Button("OK") { themeError = nil }
        } message: {
            Text(themeError ?? "")
        }
    }

    // MARK: - Sections

    private func presetSection(title: String, presets: [ThemePreset], includeSystem: Bool) -> some View {
        Section(title) {
            if includeSystem {
                themeRow(
                    name: "System default",
                    spec: nil,
                    isSelected: services.themeService.selection == .system
                ) {
                    services.themeService.selection = .system
                }
            }
            ForEach(presets) { preset in
                themeRow(
                    name: preset.displayName,
                    spec: preset.spec,
                    isSelected: services.themeService.selection == .preset(preset)
                ) {
                    services.themeService.selection = .preset(preset)
                }
            }
        }
        .listRowBackground(theme.surfaceRaised.color)
    }

    private var customThemesSection: some View {
        Section("Custom themes") {
            ForEach(services.themeService.customThemes) { spec in
                customThemeRow(spec)
            }
            Menu {
                ForEach(ThemePreset.allCases) { preset in
                    Button("From \(preset.displayName)") {
                        duplicatePreset(preset)
                    }
                }
            } label: {
                Label("New custom theme", systemImage: "plus.circle")
                    .foregroundStyle(theme.accent.color)
            }
            .premiumGated(.customThemes)

            Button {
                importingJSON = true
            } label: {
                Label("Import theme JSON", systemImage: "square.and.arrow.down")
                    .foregroundStyle(theme.accent.color)
            }
            .premiumGated(.customThemes)
        }
        .listRowBackground(theme.surfaceRaised.color)
    }

    private func customThemeRow(_ spec: ThemeSpec) -> some View {
        let uuid = ThemeService.uuid(fromSpecID: spec.id)
        let isSelected = uuid.map { services.themeService.selection == .custom($0) } ?? false
        return themeRow(name: spec.displayName, spec: spec, isSelected: isSelected) {
            if let uuid {
                services.themeService.selection = .custom(uuid)
            }
        }
        .contextMenu {
            Button {
                editingTheme = spec
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            Button {
                exportTheme(spec)
            } label: {
                Label("Export JSON", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                if let uuid {
                    try? services.themeService.deleteCustomTheme(id: uuid)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func themeRow(
        name: String,
        spec: ThemeSpec?,
        isSelected: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack(spacing: 12) {
                if let spec {
                    ThemeSwatchView(spec: spec)
                } else {
                    HStack(spacing: 2) {
                        ThemeSwatchView(spec: ThemePreset.light.spec)
                            .frame(width: 52)
                            .clipped()
                        ThemeSwatchView(spec: ThemePreset.dark.spec)
                            .frame(width: 52)
                            .clipped()
                    }
                    .frame(width: 108, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Text(name)
                    .foregroundStyle(theme.ink.color)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent.color)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var paperSection: some View {
        Section("Paper tone") {
            Picker("Paper tone", selection: paperToneBinding) {
                ForEach(PaperTone.allCases, id: \.self) { tone in
                    Text(tone.displayName).tag(tone)
                }
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(theme.surfaceRaised.color)
    }

    private var premiumSection: some View {
        PremiumSettingsSection(showPaywall: $showPaywall)
            .listRowBackground(theme.surfaceRaised.color)
    }

    #if DEBUG
    private var debugSection: some View {
        DebugSettingsSection()
            .listRowBackground(theme.surfaceRaised.color)
    }
    #endif

    // MARK: - Actions

    private func duplicatePreset(_ preset: ThemePreset) {
        do {
            let spec = try services.themeService.createCustomTheme(
                from: preset,
                named: "My \(preset.displayName)"
            )
            editingTheme = spec
        } catch {
            themeError = "Couldn't create the theme."
        }
    }

    private func exportTheme(_ spec: ThemeSpec) {
        guard let uuid = ThemeService.uuid(fromSpecID: spec.id),
              let data = try? services.themeService.exportCustomTheme(id: uuid) else {
            themeError = "Couldn't export this theme."
            return
        }
        exportPayload = ThemeJSONFile(data: data, suggestedName: spec.displayName)
    }

    private func importThemeJSON(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            _ = try services.themeService.importThemes(from: data)
        } catch {
            themeError = "That file isn't a valid theme JSON."
        }
    }

    // MARK: - Bindings

    private var paperToneBinding: Binding<PaperTone> {
        Binding(
            get: { services.themeService.paperTone },
            set: { services.themeService.paperTone = $0 }
        )
    }

    private var exportBinding: Binding<Bool> {
        Binding(
            get: { exportPayload != nil },
            set: { if !$0 { exportPayload = nil } }
        )
    }

    private var themeErrorBinding: Binding<Bool> {
        Binding(
            get: { themeError != nil },
            set: { if !$0 { themeError = nil } }
        )
    }
}

/// FileDocument wrapper for exporting a theme as JSON.
struct ThemeJSONFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data
    let suggestedName: String

    init(data: Data, suggestedName: String) {
        self.data = data
        self.suggestedName = suggestedName
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        suggestedName = "theme"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
