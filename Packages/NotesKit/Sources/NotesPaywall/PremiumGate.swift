import NotesServices
import SwiftUI

/// `.premiumGated(_:)` — the seam UI uses to gate a would-be premium feature.
///
/// ClassNotes is fully free: every feature is unlocked, so this is a
/// pass-through — no lock badge, no paywall. Kept (with the feature vocabulary)
/// so server-side entitlements could return later without touching call sites.
public struct PremiumGatedModifier: ViewModifier {
    let feature: PremiumFeature

    public func body(content: Content) -> some View {
        content
    }
}

extension View {
    public func premiumGated(_ feature: PremiumFeature) -> some View {
        modifier(PremiumGatedModifier(feature: feature))
    }
}
