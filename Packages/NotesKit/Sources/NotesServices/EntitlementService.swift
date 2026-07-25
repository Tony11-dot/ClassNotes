import Foundation
import Observation
import StoreKit

/// Everything premium, by feature. Locked features stay visible in UI and
/// route through `.premiumGated()` — this enum is the single vocabulary.
public enum PremiumFeature: String, CaseIterable, Sendable, Identifiable {
    case customThemes
    case customFonts
    case handwritingToFont // Milestone 3 — entitlement stub only
    case advancedInk
    case unlimitedNotebooks
    case ocrSearch
    case shapeTools
    case audioSync
    case advancedExport
    case cloudSync

    public var id: String { rawValue }

    /// Which purchase unlocks it: local features come with the one-time
    /// lifetime purchase OR a subscription; sync/AI features need the
    /// subscription (they have recurring server cost).
    public var tier: PremiumTier {
        switch self {
        case .customThemes, .customFonts, .advancedInk, .unlimitedNotebooks,
             .ocrSearch, .shapeTools, .audioSync, .advancedExport:
            .lifetime
        case .handwritingToFont, .cloudSync:
            .subscription
        }
    }

    public var displayName: String {
        switch self {
        case .customThemes: "Custom themes"
        case .customFonts: "Custom fonts"
        case .handwritingToFont: "Your handwriting as a font"
        case .advancedInk: "Advanced ink"
        case .unlimitedNotebooks: "Unlimited notebooks"
        case .ocrSearch: "Handwriting search"
        case .shapeTools: "Shapes & rulers"
        case .audioSync: "Audio recording"
        case .advancedExport: "Advanced export"
        case .cloudSync: "Cloud sync & collaboration"
        }
    }

    public var symbolName: String {
        switch self {
        case .customThemes: "paintpalette"
        case .customFonts: "textformat"
        case .handwritingToFont: "signature"
        case .advancedInk: "paintbrush.pointed"
        case .unlimitedNotebooks: "books.vertical"
        case .ocrSearch: "text.magnifyingglass"
        case .shapeTools: "triangle"
        case .audioSync: "waveform"
        case .advancedExport: "square.and.arrow.up.on.square"
        case .cloudSync: "icloud"
        }
    }
}

public enum PremiumTier: Sendable {
    case lifetime
    case subscription
}

public enum EntitlementError: Error, Equatable {
    case locked(PremiumFeature)
    case purchaseFailed
}

/// The ONE gate for premium state. Views never check purchases directly.
///
/// Today the state is client-derived from StoreKit's verified transactions;
/// the API is deliberately shaped (async refresh, opaque booleans) so a
/// server-side receipt validation step can replace `refreshEntitlements()`
/// internals without touching any caller.
@MainActor
@Observable
public final class EntitlementService {
    public static let lifetimeProductID = "notes.classmate.premium.lifetime"
    public static let monthlyProductID = "notes.classmate.premium.monthly"
    public static let yearlyProductID = "notes.classmate.premium.yearly"

    public static var allProductIDs: [String] {
        [lifetimeProductID, monthlyProductID, yearlyProductID]
    }

    public private(set) var hasLifetime = false
    public private(set) var hasSubscription = false
    public private(set) var products: [Product] = []
    public private(set) var lastRestoreError: String?

    /// Free-tier notebook cap. `nil` = uncapped — the number is a product
    /// decision Tony will make; wire it here and everything downstream obeys.
    public var freeNotebookLimit: Int?

    #if DEBUG
    /// Settings → Debug toggle: force premium on/off in development builds
    /// without purchasing. `nil` follows real StoreKit state.
    public var debugForcePremium: Bool? {
        didSet {
            let defaults = UserDefaults.standard
            switch debugForcePremium {
            case .none: defaults.removeObject(forKey: Self.debugDefaultsKey)
            case .some(let value): defaults.set(value, forKey: Self.debugDefaultsKey)
            }
        }
    }
    private static let debugDefaultsKey = "debug.forcePremium"
    #endif

    // Written once in init, cancelled in deinit — safe to leave nonisolated.
    @ObservationIgnored nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    public init(listenForUpdates: Bool = true) {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.debugDefaultsKey) != nil {
            debugForcePremium = defaults.bool(forKey: Self.debugDefaultsKey)
        }
        #endif
        if listenForUpdates {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update {
                        await transaction.finish()
                    }
                    await self?.refreshEntitlements()
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Queries

    // ClassNotes is fully free — every feature is unlocked for everyone. The
    // gate architecture is intentionally kept (so server-side entitlements
    // could return later), but today it always reports unlocked.
    public func isUnlocked(_ feature: PremiumFeature) -> Bool { true }

    public var isPremium: Bool { true }

    public func canCreateNotebook(currentCount: Int) -> Bool {
        if isUnlocked(.unlimitedNotebooks) { return true }
        guard let limit = freeNotebookLimit else { return true }
        return currentCount < limit
    }

    // MARK: - StoreKit

    public func refreshEntitlements() async {
        var lifetime = false
        var subscription = false
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            switch transaction.productID {
            case Self.lifetimeProductID:
                lifetime = true
            case Self.monthlyProductID, Self.yearlyProductID:
                if transaction.revocationDate == nil { subscription = true }
            default:
                break
            }
        }
        hasLifetime = lifetime
        hasSubscription = subscription
    }

    public func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.allProductIDs)
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            products = []
        }
    }

    /// Returns true when the purchase completed (not cancelled/pending).
    @discardableResult
    public func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw EntitlementError.purchaseFailed
            }
            await transaction.finish()
            await refreshEntitlements()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    public func restorePurchases() async {
        lastRestoreError = nil
        do {
            try await AppStore.sync()
        } catch {
            lastRestoreError = error.localizedDescription
        }
        await refreshEntitlements()
    }
}
