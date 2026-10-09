import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Whether NOVA may send what the user asks about to the AI provider.
///
/// NOVA asks the first time it would send anything (`NovaConsentCard`); this is
/// where that answer is changed. Turning it off takes effect at once: the next
/// question waits for permission again, and nothing already held is sent.
struct NovaPrivacySection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { services.novaConsent.isGranted },
                set: { allowed in
                    if allowed { services.novaConsent.grant() } else { services.novaConsent.revoke() }
                }
            )) {
                Label {
                    Text("Let NOVA send what you ask")
                        .foregroundStyle(theme.ink.color)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(theme.accent.color)
                }
            }
            .tint(theme.accent.color)
        } header: {
            Text("NOVA and privacy")
        } footer: {
            Text("""
                 NOVA answers by sending your message, anything you circle or snip, \
                 and, when you ask it to read a notebook, that notebook's pages, to \
                 the ClassNotes server and on to Groq, the AI service that writes the \
                 reply. It never reads your notes on its own. Off: NOVA asks before \
                 sending anything.
                 """)
                .font(.dsCaption)
                .foregroundStyle(theme.inkSecondary.color)
        }
        .listRowBackground(theme.surfaceRaised.color)
    }
}
