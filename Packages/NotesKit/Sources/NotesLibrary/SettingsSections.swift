import NotesServices
import SwiftUI

struct PremiumSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    @Binding var showPaywall: Bool

    var body: some View {
        Section("Premium") {
            HStack {
                Label(
                    services.entitlements.isPremium ? "Premium active" : "Free plan",
                    systemImage: services.entitlements.isPremium ? "checkmark.seal.fill" : "seal"
                )
                .foregroundStyle(theme.ink.color)
                Spacer()
            }
            Button("View Premium") { showPaywall = true }
                .foregroundStyle(theme.accent.color)
            Button("Restore Purchases") {
                Task { await services.entitlements.restorePurchases() }
            }
            .foregroundStyle(theme.accent.color)
        }
    }
}

#if DEBUG
/// Development-only: flip entitlement state without buying anything.
struct DebugSettingsSection: View {
    @Environment(AppServices.self) private var services

    private enum Choice: Hashable {
        case followStoreKit
        case forcePremium
        case forceFree
    }

    var body: some View {
        Section("Debug") {
            Picker("Entitlement override", selection: binding) {
                Text("Follow StoreKit").tag(Choice.followStoreKit)
                Text("Force Premium").tag(Choice.forcePremium)
                Text("Force Free").tag(Choice.forceFree)
            }
        }
    }

    private var binding: Binding<Choice> {
        Binding(
            get: {
                switch services.entitlements.debugForcePremium {
                case .none: .followStoreKit
                case .some(true): .forcePremium
                case .some(false): .forceFree
                }
            },
            set: { choice in
                switch choice {
                case .followStoreKit: services.entitlements.debugForcePremium = nil
                case .forcePremium: services.entitlements.debugForcePremium = true
                case .forceFree: services.entitlements.debugForcePremium = false
                }
            }
        )
    }
}
#endif
