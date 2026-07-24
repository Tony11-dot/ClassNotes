import Foundation
import Testing
@testable import NotesServices

@MainActor
@Suite("Entitlements", .serialized)
struct EntitlementTests {
    private func makeService() -> EntitlementService {
        let service = EntitlementService(listenForUpdates: false)
        service.debugForcePremium = nil
        return service
    }

    @Test("Local features ride the lifetime tier; sync/AI need the subscription")
    func tiers() {
        #expect(PremiumFeature.customThemes.tier == .lifetime)
        #expect(PremiumFeature.advancedInk.tier == .lifetime)
        #expect(PremiumFeature.unlimitedNotebooks.tier == .lifetime)
        #expect(PremiumFeature.cloudSync.tier == .subscription)
        #expect(PremiumFeature.handwritingToFont.tier == .subscription)
    }

    @Test("Everything is locked by default without purchases")
    func lockedByDefault() {
        let service = makeService()
        defer { service.debugForcePremium = nil }
        for feature in PremiumFeature.allCases {
            #expect(!service.isUnlocked(feature))
        }
        #expect(!service.isPremium)
    }

    @Test("Debug override forces both states for device testing")
    func debugOverride() {
        let service = makeService()
        defer { service.debugForcePremium = nil }

        service.debugForcePremium = true
        for feature in PremiumFeature.allCases {
            #expect(service.isUnlocked(feature))
        }

        service.debugForcePremium = false
        for feature in PremiumFeature.allCases {
            #expect(!service.isUnlocked(feature))
        }
    }

    @Test("Debug override persists like the real toggle will")
    func debugOverridePersists() {
        let service = makeService()
        service.debugForcePremium = true
        let second = EntitlementService(listenForUpdates: false)
        #expect(second.debugForcePremium == true)
        service.debugForcePremium = nil
        #expect(EntitlementService(listenForUpdates: false).debugForcePremium == nil)
    }

    @Test("Notebook cap: uncapped until the free limit is chosen, then enforced")
    func notebookCap() {
        let service = makeService()
        defer { service.debugForcePremium = nil }
        service.debugForcePremium = false

        // No cap picked yet — free tier is uncapped.
        #expect(service.canCreateNotebook(currentCount: 500))

        service.freeNotebookLimit = 3
        #expect(service.canCreateNotebook(currentCount: 2))
        #expect(!service.canCreateNotebook(currentCount: 3))

        // Premium ignores the cap.
        service.debugForcePremium = true
        #expect(service.canCreateNotebook(currentCount: 3))
    }
}
