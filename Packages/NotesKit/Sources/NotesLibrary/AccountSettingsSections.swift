import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Account row at the top of Settings — avatar, name, tap → Profile.
struct AccountSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @State private var showProfile = false
    @State private var showSignIn = false

    var body: some View {
        Section {
            if services.auth.state == .authenticated {
                profileRow
            } else {
                signInRow
            }
        }
        .listRowBackground(theme.surfaceRaised.color)
        .sheet(isPresented: $showProfile) { ProfileScreen() }
        .fullScreenCover(isPresented: $showSignIn) { LoginScreen(asSheet: true) }
    }

    /// Working without an account: what one adds, and the way in.
    private var signInRow: some View {
        Button {
            showSignIn = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(theme.accentMuted.color)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.dsHeadline)
                        .foregroundStyle(theme.accent.color)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in or create an account")
                        .font(.dsBody.weight(.semibold))
                        .foregroundStyle(theme.ink.color)
                    Text("Sync your notebooks to ClassMate, use NOVA, and keep your settings on every device.")
                        .font(.dsCaption)
                        .foregroundStyle(theme.inkSecondary.color)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(theme.inkSecondary.color)
            }
        }
        .buttonStyle(.plain)
    }

    private var profileRow: some View {
        Button {
            showProfile = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(theme.accentMuted.color)
                    Text(services.auth.account?.initial ?? "?")
                        .font(.dsHeadline.weight(.heavy))
                        .foregroundStyle(theme.accent.color)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(services.auth.account?.displayName ?? "Your profile")
                        .font(.dsBody.weight(.semibold))
                        .foregroundStyle(theme.ink.color)
                    // The email, where ClassMate's @username used to be: a
                    // ClassNotes account has no username to show.
                    if let email = services.auth.account?.email {
                        Text(email)
                            .font(.dsCaption)
                            .foregroundStyle(theme.inkSecondary.color)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(theme.inkSecondary.color)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Which help sheet is open. Presented from `SettingsScreen` (a stable
/// NavigationStack ancestor) — NOT from the Section itself. Attaching a `.sheet`
/// to List-row/Section content tears its transient `@State` down as the List
/// re-evaluates, which is why About/Support opened then vanished immediately.
enum HelpSheet: String, Identifiable {
    case support, about
    var id: String { rawValue }
}

/// About / Support / Privacy links at the bottom of Settings. The parent owns
/// the sheet presentation; this section just reports which link was tapped.
struct AboutSettingsSection: View {
    @Environment(\.theme) private var theme
    let onSelect: (HelpSheet) -> Void

    var body: some View {
        Section {
            Button { onSelect(.support) } label: {
                Label("Support", systemImage: "questionmark.circle")
            }
            Button { onSelect(.about) } label: {
                Label("About", systemImage: "info.circle")
            }
            Link(destination: ClassMateLinks.privacy) {
                Label("Privacy Policy", systemImage: "shield")
            }
            Link(destination: ClassMateLinks.accessibility) {
                Label("Accessibility", systemImage: "accessibility")
            }
        } header: {
            Text("Help")
        } footer: {
            Text("ClassNotes · v\(ClassMateLinks.appVersion)")
        }
        .tint(theme.accent.color)
        .listRowBackground(theme.surfaceRaised.color)
    }
}
