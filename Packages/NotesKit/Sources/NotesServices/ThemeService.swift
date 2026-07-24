import ClassMateTheme
import Foundation
import NotesModels
import Observation
import SwiftData

/// Theme selection, custom themes, and graceful degradation.
///
/// Custom themes are premium; if entitlement lapses, a selected custom theme
/// resolves to its NEAREST PRESET instead of breaking — notebooks always keep
/// a coherent appearance and the user's data is never touched.
@MainActor
@Observable
public final class ThemeService {
    private let context: ModelContext
    private let entitlements: EntitlementService

    public private(set) var customThemes: [ThemeSpec] = []

    public var selection: ThemeSelection {
        didSet { persistPreferences() }
    }

    public var paperTone: PaperTone {
        didSet { persistPreferences() }
    }

    public init(context: ModelContext, entitlements: EntitlementService) {
        self.context = context
        self.entitlements = entitlements

        let preferences = Self.loadOrCreatePreferences(in: context)
        self.selection = ThemeSelection(rawValue: preferences.themeSelectionRaw) ?? .system
        self.paperTone = PaperTone(rawValue: preferences.paperToneRaw) ?? .neutral
        reloadCustomThemes()
    }

    // MARK: - Resolution

    /// The active spec. `prefersDark` is the OS appearance, used only when the
    /// selection is `.system`.
    public func spec(prefersDark: Bool) -> ThemeSpec {
        switch selection {
        case .system:
            return ThemeSelection.systemSpec(prefersDark: prefersDark)
        case .preset(let preset):
            return preset.spec
        case .custom(let id):
            guard let custom = customThemes.first(where: { $0.id == Self.specID(for: id) }) else {
                return ThemeSelection.systemSpec(prefersDark: prefersDark)
            }
            guard entitlements.isUnlocked(.customThemes) else {
                return ThemePreset.nearest(to: custom).spec
            }
            return custom
        }
    }

    /// When a fixed theme is selected the app pins the color scheme; `nil`
    /// (for `.system`) hands control back to the OS.
    public func pinnedDarkMode(prefersDark: Bool) -> Bool? {
        if case .system = selection { return nil }
        return spec(prefersDark: prefersDark).isDark
    }

    // MARK: - Custom themes (premium)

    @discardableResult
    public func createCustomTheme(from preset: ThemePreset, named name: String) throws -> ThemeSpec {
        guard entitlements.isUnlocked(.customThemes) else {
            throw EntitlementError.locked(.customThemes)
        }
        let id = UUID()
        var spec = preset.spec
        spec.id = Self.specID(for: id)
        spec.displayName = name
        let record = CustomThemeRecord(id: id, name: name, specJSON: try JSONEncoder().encode(spec))
        context.insert(record)
        try context.save()
        reloadCustomThemes()
        return spec
    }

    public func updateCustomTheme(_ spec: ThemeSpec) throws {
        guard entitlements.isUnlocked(.customThemes) else {
            throw EntitlementError.locked(.customThemes)
        }
        guard let id = Self.uuid(fromSpecID: spec.id),
              let record = try fetchRecord(id: id) else { return }
        record.name = spec.displayName
        record.specJSON = try JSONEncoder().encode(spec)
        record.updatedAt = .now
        try context.save()
        reloadCustomThemes()
    }

    public func deleteCustomTheme(id: UUID) throws {
        guard let record = try fetchRecord(id: id) else { return }
        context.delete(record)
        try context.save()
        if case .custom(let selected) = selection, selected == id {
            selection = .system
        }
        reloadCustomThemes()
    }

    // MARK: - JSON import/export

    public func exportCustomTheme(id: UUID) throws -> Data {
        guard let spec = customThemes.first(where: { $0.id == Self.specID(for: id) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ThemeJSON.encode([spec])
    }

    @discardableResult
    public func importThemes(from data: Data) throws -> [ThemeSpec] {
        guard entitlements.isUnlocked(.customThemes) else {
            throw EntitlementError.locked(.customThemes)
        }
        let imported = try ThemeJSON.decode(data)
        var saved: [ThemeSpec] = []
        for var spec in imported {
            let id = UUID()
            spec.id = Self.specID(for: id)
            let record = CustomThemeRecord(
                id: id,
                name: spec.displayName,
                specJSON: try JSONEncoder().encode(spec)
            )
            context.insert(record)
            saved.append(spec)
        }
        try context.save()
        reloadCustomThemes()
        return saved
    }

    // MARK: - Internals

    public static func specID(for uuid: UUID) -> String { "custom-\(uuid.uuidString)" }

    public static func uuid(fromSpecID specID: String) -> UUID? {
        guard specID.hasPrefix("custom-") else { return nil }
        return UUID(uuidString: String(specID.dropFirst("custom-".count)))
    }

    private func reloadCustomThemes() {
        let descriptor = FetchDescriptor<CustomThemeRecord>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        customThemes = records.compactMap { record in
            try? JSONDecoder().decode(ThemeSpec.self, from: record.specJSON)
        }
    }

    // Fetch-all-then-filter is deliberate: both tables are tiny (one prefs
    // row, a handful of custom themes), so predicate machinery buys nothing.
    private func fetchRecord(id: UUID) throws -> CustomThemeRecord? {
        try context.fetch(FetchDescriptor<CustomThemeRecord>())
            .first { $0.id == id }
    }

    private func persistPreferences() {
        let preferences = Self.loadOrCreatePreferences(in: context)
        preferences.themeSelectionRaw = selection.rawValue
        preferences.paperToneRaw = paperTone.rawValue
        try? context.save()
    }

    private static func loadOrCreatePreferences(in context: ModelContext) -> AppPreferences {
        let all = (try? context.fetch(FetchDescriptor<AppPreferences>())) ?? []
        if let existing = all.first(where: { $0.key == AppPreferences.singletonKey }) {
            return existing
        }
        let fresh = AppPreferences()
        context.insert(fresh)
        try? context.save()
        return fresh
    }
}
