import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// NOVA chat surface: user messages as accent bubbles, assistant replies as
/// avatar + plain streaming text (ClassMate style — no assistant bubble).
/// Presented as a sheet from the editor (circle-to-explain) and from Support.
public struct NovaChatView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var conversation: NovaConversation
    @State private var draft = ""
    private let title: String

    public init(conversation: NovaConversation, title: String = "NOVA") {
        self._conversation = State(initialValue: conversation)
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground(seed: 7, opacity: 0.7)
                VStack(spacing: 0) {
                    transcript
                    composer
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NovaAvatar(size: 26, animated: conversation.streaming)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if conversation.visibleMessages.isEmpty {
                        emptyState
                    }
                    ForEach(conversation.visibleMessages) { message in
                        messageRow(message).id(message.id)
                    }
                    if conversation.streaming, conversation.visibleMessages.last?.content.isEmpty ?? true {
                        HStack(spacing: 10) {
                            NovaAvatar(size: 26, animated: true)
                            TypingDots()
                        }
                    }
                    if let error = conversation.errorText {
                        Text(error)
                            .font(.dsFootnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
            .onChange(of: conversation.visibleMessages.last?.content) { _, _ in
                if let last = conversation.visibleMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: AIMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(theme.accent.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                NovaAvatar(size: 26)
                if message.content.isEmpty {
                    NovaTypingDots()
                } else {
                    NovaMarkdownText(message.content)
                        .foregroundStyle(theme.ink.color)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            NovaAvatar(size: 40)
            Text("Ask NOVA")
                .font(.dsTitle3.weight(.bold))
                .foregroundStyle(theme.ink.color)
            Text("""
                 Explain a concept, turn notes into a table, or quiz yourself. \
                 NOVA can make mistakes — double-check important answers.
                 """)
                .font(.dsSubheadline)
                .foregroundStyle(theme.inkSecondary.color)
        }
        .padding(.vertical, 12)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message NOVA", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    theme.surfaceRaised.color,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            Button {
                conversation.send(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.dsSystem(size: 30))
                    .foregroundStyle(theme.accent.color)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || conversation.streaming)
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }
}
