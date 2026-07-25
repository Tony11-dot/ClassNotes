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

    @Test("ClassNotes is fully free — every feature is unlocked for everyone")
    func everythingUnlocked() {
        let service = makeService()
        for feature in PremiumFeature.allCases {
            #expect(service.isUnlocked(feature))
        }
        #expect(service.isPremium)
    }

    @Test("Notebook creation is always allowed — no cap on a free app")
    func notebookCreationUncapped() {
        let service = makeService()
        #expect(service.canCreateNotebook(currentCount: 500))

        // Even if a legacy free limit is set, unlocked entitlement wins.
        service.freeNotebookLimit = 3
        #expect(service.canCreateNotebook(currentCount: 3))
        #expect(service.canCreateNotebook(currentCount: 9_999))
    }
}
