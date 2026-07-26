import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Account row at the top of Settings — avatar, name, tap → Profile.
struct AccountSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @State private var showProfile = false

    var body: some View {
        Section {
            Button {
                showProfile = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(theme.accentMuted.color)
                        Text(services.auth.user?.initials ?? "?")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(theme.accent.color)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(services.auth.user?.bestName ?? "Your profile")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.ink.color)
                        if let username = services.auth.user?.username {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(theme.inkSecondary.color)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(theme.inkSecondary.color)
                }
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(theme.surfaceRaised.color)
        .sheet(isPresented: $showProfile) { ProfileScreen() }
    }
}

/// NOVA / AI — built in, no setup. NOVA runs through ClassMate's servers using
/// your signed-in account, so there's nothing to configure (no API key).
struct NovaSettingsSection: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            HStack(spacing: 12) {
                NovaAvatar(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOVA is ready")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.ink.color)
                    Text("Your AI study buddy — built in, nothing to set up.")
                        .font(.caption)
                        .foregroundStyle(theme.inkSecondary.color)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(theme.accent.color)
            }
        } header: {
            Text("NOVA (AI)")
        } footer: {
            Text("NOVA works automatically while you're signed in — highlight anything on a page and ask her to explain or tidy it up.")
        }
        .listRowBackground(theme.surfaceRaised.color)
    }
}

/// About / Support / Privacy links at the bottom of Settings.
struct AboutSettingsSection: View {
    @Environment(\.theme) private var theme

    /// Which help sheet is open. A SINGLE `.sheet(item:)` — two adjacent
    /// `.sheet(isPresented:)` modifiers on one view is a known SwiftUI pitfall
    /// where only one registers, which is why About/Support wouldn't open.
    private enum HelpSheet: String, Identifiable {
        case support, about
        var id: String { rawValue }
    }
    @State private var sheet: HelpSheet?

    var body: some View {
        Section {
            Button { sheet = .support } label: {
                Label("Support", systemImage: "questionmark.circle")
            }
            Button { sheet = .about } label: {
                Label("About", systemImage: "info.circle")
            }
            Link(destination: ClassMateLinks.privacy) {
                Label("Privacy Policy", systemImage: "shield")
            }
        } header: {
            Text("Help")
        } footer: {
            Text("ClassNotes · v\(ClassMateLinks.appVersion)")
        }
        .tint(theme.accent.color)
        .listRowBackground(theme.surfaceRaised.color)
        .sheet(item: $sheet) { which in
            switch which {
            case .support: SupportScreen()
            case .about: AboutScreen()
            }
        }
    }
}
