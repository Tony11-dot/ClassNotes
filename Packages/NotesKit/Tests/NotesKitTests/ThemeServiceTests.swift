import ClassMateTheme
import Foundation
import NotesModels
import SwiftData
import Testing
@testable import NotesServices

@MainActor
@Suite("ThemeService", .serialized)
struct ThemeServiceTests {
    /// Bundles the container with the services — contexts don't retain their
    /// container, and a dropped container traps on the next store operation.
    @MainActor
    private struct Harness {
        let container: ModelContainer
        let themes: ThemeService
        let entitlements: EntitlementService
        var context: ModelContext { container.mainContext }
    }

    private func makeServices() -> Harness {
        let container = ModelContainerFactory.make(inMemory: true)
        let entitlements = EntitlementService(listenForUpdates: false)
        entitlements.debugForcePremium = nil
        let themes = ThemeService(context: container.mainContext, entitlements: entitlements)
        return Harness(container: container, themes: themes, entitlements: entitlements)
    }

    @Test("Defaults to following the system between Light and Dark")
    func defaults() {
        let harness = makeServices()
        defer { harness.entitlements.debugForcePremium = nil }
        #expect(harness.themes.selection == .system)
        #expect(harness.themes.spec(prefersDark: false).id == "light")
        #expect(harness.themes.spec(prefersDark: true).id == "dark")
        #expect(harness.themes.pinnedDarkMode(prefersDark: false) == nil)
    }

    @Test("Preset selection resolves and persists across service instances")
    func persistence() {
        let harness = makeServices()
        defer { harness.entitlements.debugForcePremium = nil }

        harness.themes.selection = .preset(.nord)
        harness.themes.paperTone = .warm
        #expect(harness.themes.spec(prefersDark: false).id == "nord")
        #expect(harness.themes.pinnedDarkMode(prefersDark: false) == true)

        let second = ThemeService(context: harness.context, entitlements: harness.entitlements)
        #expect(second.selection == .preset(.nord))
        #expect(second.paperTone == .warm)
    }

    @Test("Custom theme lifecycle: create from preset, edit, select, delete")
    func customLifecycle() throws {
        let harness = makeServices()
        harness.entitlements.debugForcePremium = true
        defer { harness.entitlements.debugForcePremium = nil }

        var spec = try harness.themes.createCustomTheme(from: .matcha, named: "My Matcha")
        #expect(harness.themes.customThemes.count == 1)

        spec.accent = ThemeColor(hex: "#417262")!
        try harness.themes.updateCustomTheme(spec)
        #expect(harness.themes.customThemes[0].accent.hexString == "#417262")

        let uuid = try #require(ThemeService.uuid(fromSpecID: spec.id))
        harness.themes.selection = .custom(uuid)
        #expect(harness.themes.spec(prefersDark: false).id == spec.id)

        try harness.themes.deleteCustomTheme(id: uuid)
        #expect(harness.themes.customThemes.isEmpty)
        #expect(harness.themes.selection == .system)
    }

    @Test("Creating a custom theme without entitlement throws")
    func lockedCreation() {
        let harness = makeServices()
        harness.entitlements.debugForcePremium = false
        defer { harness.entitlements.debugForcePremium = nil }

        #expect(throws: EntitlementError.locked(.customThemes)) {
            try harness.themes.createCustomTheme(from: .wine, named: "Nope")
        }
    }

    @Test("Losing premium degrades a selected custom theme to its nearest preset")
    func gracefulDegradation() throws {
        let harness = makeServices()
        harness.entitlements.debugForcePremium = true

        var spec = try harness.themes.createCustomTheme(from: .wine, named: "Cellar Door")
        spec.accent = ThemeColor(
            red: spec.accent.red,
            green: spec.accent.green + 0.03,
            blue: spec.accent.blue
        )
        try harness.themes.updateCustomTheme(spec)
        let uuid = try #require(ThemeService.uuid(fromSpecID: spec.id))
        harness.themes.selection = .custom(uuid)
        #expect(harness.themes.spec(prefersDark: false).id == spec.id)

        // Premium lapses: appearance falls back to the nearest preset (wine),
        // the custom theme and the user's notebooks stay untouched.
        harness.entitlements.debugForcePremium = false
        defer { harness.entitlements.debugForcePremium = nil }
        #expect(harness.themes.spec(prefersDark: false).id == "wine")
        #expect(harness.themes.customThemes.count == 1)
    }

    @Test("Export → import round-trips a custom theme with a fresh identity")
    func exportImport() throws {
        let harness = makeServices()
        harness.entitlements.debugForcePremium = true
        defer { harness.entitlements.debugForcePremium = nil }

        let original = try harness.themes.createCustomTheme(from: .plum, named: "Twilight")
        let uuid = try #require(ThemeService.uuid(fromSpecID: original.id))
        let data = try harness.themes.exportCustomTheme(id: uuid)

        let imported = try harness.themes.importThemes(from: data)
        #expect(imported.count == 1)
        #expect(imported[0].id != original.id)
        #expect(imported[0].displayName == "Twilight")
        #expect(imported[0].accent == original.accent)
        #expect(harness.themes.customThemes.count == 2)
    }

    @Test("A missing custom selection falls back to system safely")
    func missingCustom() {
        let harness = makeServices()
        defer { harness.entitlements.debugForcePremium = nil }
        harness.themes.selection = .custom(UUID())
        #expect(harness.themes.spec(prefersDark: true).id == "dark")
    }
}
