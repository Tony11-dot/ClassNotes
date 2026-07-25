import NotesServices
import SwiftUI

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
