import NotesAI
import NotesServices
import SwiftUI

/// Presents NOVA as a standalone assistant (from Support). The editor presents
/// its own conversation seeded by circle-to-explain.
struct NovaSupportSheet: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        NovaChatView(conversation: services.makeNovaConversation())
    }
}
