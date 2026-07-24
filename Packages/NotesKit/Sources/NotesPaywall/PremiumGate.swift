import NotesDesignSystem
import NotesServices
import SwiftUI

/// `.premiumGated(_:)` — the ONLY way UI gates a premium feature.
///
/// Unlocked: the content is untouched. Locked: the content stays fully
/// visible (never hidden), is inert, wears a small lock badge, and a tap
/// opens the paywall sheet highlighting the tapped feature.
public struct PremiumGatedModifier: ViewModifier {
    @Environment(EntitlementService.self) private var entitlements
    @Environment(\.theme) private var theme

    let feature: PremiumFeature

    @State private var showPaywall = false

    @ViewBuilder
    public func body(content: Content) -> some View {
        if entitlements.isUnlocked(feature) {
            content
        } else {
            content
                .disabled(true)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                        .padding(5)
                        .background(theme.accentMuted.color, in: Circle())
                        .padding(4)
                        .accessibilityLabel("\(feature.displayName) is a Premium feature")
                }
                .contentShape(Rectangle())
                .onTapGesture { showPaywall = true }
                .sheet(isPresented: $showPaywall) {
                    PaywallView(highlighting: feature)
                }
        }
    }
}

extension View {
    public func premiumGated(_ feature: PremiumFeature) -> some View {
        modifier(PremiumGatedModifier(feature: feature))
    }
}
