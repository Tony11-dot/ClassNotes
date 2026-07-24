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

/// NOVA / AI settings — the Groq key entry (stored in Keychain).
struct NovaSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        Section {
            HStack(spacing: 10) {
                NovaAvatar(size: 26)
                SecureField("Groq API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(theme.ink.color)
                if saved {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent.color)
                }
            }
            Button("Save key") {
                services.groqAPIKey = key
                saved = true
            }
            .foregroundStyle(theme.accent.color)
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            Link("Get a free key at console.groq.com",
                 destination: URL(string: "https://console.groq.com/keys")!)
                .font(.caption)
                .foregroundStyle(theme.inkSecondary.color)
        } header: {
            Text("NOVA (AI)")
        } footer: {
            Text("""
                 NOVA uses Groq's free API (same setup as ClassMate). A key \
                 built into the app is used first; otherwise this key is stored \
                 only in the Keychain and never leaves the device except to call Groq.
                 """)
        }
        .listRowBackground(theme.surfaceRaised.color)
        .onAppear { key = services.groqAPIKey }
    }
}

/// About / Support / Privacy links at the bottom of Settings.
struct AboutSettingsSection: View {
    @Environment(\.theme) private var theme
    @State private var showAbout = false
    @State private var showSupport = false

    var body: some View {
        Section {
            Button { showSupport = true } label: {
                Label("Support", systemImage: "questionmark.circle")
            }
            Button { showAbout = true } label: {
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
        .sheet(isPresented: $showAbout) { AboutScreen() }
        .sheet(isPresented: $showSupport) { SupportScreen() }
    }
}
