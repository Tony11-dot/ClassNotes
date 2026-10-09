import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// Asks before anything goes to the AI provider, and says exactly what would.
///
/// Shown in place of an answer while `NovaConversation.awaitingConsent`: the
/// question stays on screen, nothing has been sent, and "Not now" puts typed
/// words back in the composer.
struct NovaConsentCard: View {
    @Environment(\.theme) private var theme
    let conversation: NovaConversation
    /// The composer's text, which gets typed words back on "Not now".
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(theme.accent.color)
                Text("Send this to NOVA?")
                    .font(.dsHeadline)
                    .foregroundStyle(theme.ink.color)
            }
            Text("""
                 To answer, NOVA sends what you share with it to the ClassNotes \
                 server, which passes it to Groq, the AI service that writes the reply.
                 """)
                .font(.dsFootnote)
                .foregroundStyle(theme.ink.color)
            VStack(alignment: .leading, spacing: 6) {
                point("Your message and this chat so far")
                point("Anything you circle or snip, as a picture")
                point("""
                      If you tap Read this notebook: a picture of every page, the \
                      words on them, and with each later question, the pages that match it
                      """)
            }
            Text("NOVA never reads your notes on its own. You can turn this off in Settings.")
                .font(.dsCaption)
                .foregroundStyle(theme.inkSecondary.color)
            HStack(spacing: 10) {
                Button {
                    conversation.allowAndContinue()
                } label: {
                    Text("Allow")
                        .font(.dsSubheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                        .background(theme.accent.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    if let typed = conversation.declinePending(), draft.isEmpty { draft = typed }
                } label: {
                    Text("Not now")
                        .font(.dsSubheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(theme.ink.color)
                        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Link("Privacy Policy", destination: ClassMateLinks.privacy)
                .font(.dsCaption.weight(.medium))
                .foregroundStyle(theme.accent.color)
        }
        .padding(16)
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    private func point(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(theme.accent.color)
            Text(text)
                .font(.dsFootnote)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One message in the transcript with what it carried or where it came from:
/// the pages sent with a grounded question, and the source of its answer.
struct NovaTranscriptEntry: View {
    let message: AIMessage
    let conversation: NovaConversation
    var onEdit: (() -> Void)?
    var onOpenPage: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NovaMessageRow(message: message, onEdit: onEdit)
            if message.role == .user, let context = conversation.grounding[message.id] {
                NovaGroundingCaption(context: context)
            }
            // Not while the answer is still arriving: its citations aren't in yet.
            if message.role == .assistant, !message.content.isEmpty, !isArriving,
               let source = conversation.source(ofReply: message.id) {
                NovaSourceBadge(source: source, onOpenPage: onOpenPage)
                    .padding(.leading, 34) // clears the avatar column
            }
        }
    }

    private var isArriving: Bool {
        conversation.streaming && message.id == conversation.visibleMessages.last?.id
    }
}

/// "Answering from this notebook" with a way out, for as long as questions
/// carry the notebook's pages. Grounding is never silent.
struct NovaNotebookChip: View {
    @Environment(\.theme) private var theme
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.pages")
            Text("Answering from this notebook")
                .font(.dsCaption.weight(.semibold))
            Spacer(minLength: 4)
            Button(action: onStop) {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop answering from this notebook")
        }
        .foregroundStyle(theme.accent.color)
        .padding(.leading, 12)
        .background(theme.accentMuted.withAlpha(0.16).color, in: Capsule())
    }
}

/// Under a grounded question: which pages went with it.
struct NovaGroundingCaption: View {
    @Environment(\.theme) private var theme
    let context: NovaGrounding.Context

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "book.pages")
            Text(text)
        }
        .font(.dsCaption2)
        .foregroundStyle(theme.inkSecondary.color)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var text: String {
        if context.matched.isEmpty {
            let count = context.included.count
            return "Sent \(count) page\(count == 1 ? "" : "s") of this notebook"
        }
        return "Sent " + NovaPageList.describe(context.matched) + " with this question"
    }
}

/// Under a grounded answer: where it says it came from. Cited pages open the
/// page.
struct NovaSourceBadge: View {
    @Environment(\.theme) private var theme
    let source: NovaReply.Source
    var onOpenPage: ((Int) -> Void)?

    var body: some View {
        switch source {
        case .generalKnowledge:
            Label("General knowledge, not from your notes", systemImage: "globe")
                .font(.dsCaption2.weight(.medium))
                .foregroundStyle(theme.inkSecondary.color)
        case .notes(let pages):
            HStack(spacing: 6) {
                Label("From your notes", systemImage: "checkmark.seal")
                    .font(.dsCaption2.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
                ForEach(pages, id: \.self) { page in
                    Button {
                        onOpenPage?(page)
                    } label: {
                        Text(page == 0 ? "Cover" : "p. \(page)")
                            .font(.dsCaption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 28)
                            .background(theme.accentMuted.withAlpha(0.16).color, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent.color)
                    .disabled(onOpenPage == nil)
                    .accessibilityLabel(page == 0 ? "Open the cover" : "Open page \(page)")
                }
            }
        }
    }
}

/// "page 3", "pages 2 and 5", "pages 1, 4 and 6", with the cover by name.
enum NovaPageList {
    static func describe(_ pages: [Int]) -> String {
        let numbered = pages.filter { $0 != 0 }
        var parts: [String] = []
        if pages.contains(0) { parts.append("the cover") }
        if !numbered.isEmpty {
            parts.append((numbered.count == 1 ? "page " : "pages ") + joined(numbered.map(String.init)))
        }
        return parts.joined(separator: " and ")
    }

    private static func joined(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
