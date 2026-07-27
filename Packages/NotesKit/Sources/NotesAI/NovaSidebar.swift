import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// NOVA's in-notebook sidebar.
///
/// Every notebook has a floating NOVA bubble; tapping it slides this panel in from
/// the trailing edge. The conversation is *saved* — closing the sidebar, or the
/// notebook, keeps the thread, and the history list reopens any earlier chat about
/// these notes. Circling something on the page seeds a message straight into it.
public struct NovaSidebar: View {
    @Environment(\.theme) private var theme

    private let conversation: NovaConversation
    private let store: NovaChatStore
    private let notebookID: UUID?
    private let onClose: () -> Void

    @State private var chat: NovaChat?
    @State private var draft = ""
    @State private var showHistory = false
    /// Debounces transcript writes while a reply streams in token by token.
    @State private var saveTask: Task<Void, Never>?

    public init(
        conversation: NovaConversation,
        store: NovaChatStore,
        notebookID: UUID?,
        chat: NovaChat? = nil,
        onClose: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.store = store
        self.notebookID = notebookID
        self.onClose = onClose
        _chat = State(initialValue: chat)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.separator.color)
            if showHistory {
                historyList
            } else {
                transcript
                composer
            }
        }
        .frame(width: 372)
        .frame(maxHeight: .infinity)
        .background(theme.surface.color)
        .overlay(alignment: .leading) {
            Rectangle().frame(width: 0.5).foregroundStyle(theme.separator.color)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, x: -6)
        .task { await attachChat() }
        // Persist whenever the transcript settles (streaming finished or the last
        // token landed), so a saved chat is never a partial reply.
        .onChange(of: conversation.streaming) { _, isStreaming in
            if !isStreaming { persist() }
        }
        .onChange(of: conversation.visibleMessages.count) { _, _ in schedulePersist() }
        .onDisappear {
            saveTask?.cancel()
            persist()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            NovaAvatar(size: 26, animated: conversation.streaming)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat?.title ?? "NOVA")
                    .font(.dsSubheadline.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Text(conversation.streaming ? "Thinking…" : "Saved to this notebook")
                    .font(.dsCaption2)
                    .foregroundStyle(theme.inkSecondary.color)
            }
            Spacer()
            Button {
                startNewChat()
            } label: {
                Image(systemName: "plus.bubble")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink.color)
            .accessibilityLabel("New chat")

            Button {
                showHistory.toggle()
            } label: {
                Image(systemName: showHistory ? "bubble.left.and.text.bubble.right" : "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .foregroundStyle(showHistory ? theme.accent.color : theme.ink.color)
            .accessibilityLabel(showHistory ? "Back to chat" : "Saved chats")

            Button {
                onClose()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink.color)
            .accessibilityLabel("Hide NOVA")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation.visibleMessages.isEmpty {
                        emptyState
                    }
                    ForEach(conversation.visibleMessages) { message in
                        NovaMessageRow(message: message).id(message.id)
                    }
                    if conversation.streaming, conversation.visibleMessages.last?.content.isEmpty ?? true {
                        HStack(spacing: 10) {
                            NovaAvatar(size: 24, animated: true)
                            TypingDots()
                        }
                    }
                    if let error = conversation.errorText {
                        Text(error).font(.dsFootnote).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .onChange(of: conversation.visibleMessages.last?.content) { _, _ in
                if let last = conversation.visibleMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            NovaAvatar(size: 38)
            Text("Ask NOVA about these notes")
                .font(.dsHeadline)
                .foregroundStyle(theme.ink.color)
            Text("""
                 Circle anything on the page and NOVA explains it. Or just ask — \
                 summarise a page, build a quiz, define a term. Chats stay with this \
                 notebook.
                 """)
                .font(.dsFootnote)
                .foregroundStyle(theme.inkSecondary.color)
        }
        .padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message NOVA", text: $draft, axis: .vertical)
                .lineLimit(1...5)
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
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || conversation.streaming)
            .accessibilityLabel("Send")
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Saved chats

    private var historyList: some View {
        let saved = store.chats(notebookID: notebookID)
        return Group {
            if saved.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.dsSystem(size: 26))
                        .foregroundStyle(theme.inkSecondary.color)
                    Text("No saved chats yet")
                        .font(.dsSubheadline)
                        .foregroundStyle(theme.inkSecondary.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(saved) { saved in
                        Button {
                            open(saved)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(saved.title)
                                    .font(.dsSubheadline.weight(.medium))
                                    .foregroundStyle(theme.ink.color)
                                    .lineLimit(1)
                                Text(saved.preview)
                                    .font(.dsCaption)
                                    .foregroundStyle(theme.inkSecondary.color)
                                    .lineLimit(2)
                                Text(saved.updatedAt, format: .relative(presentation: .named))
                                    .font(.dsCaption2)
                                    .foregroundStyle(theme.inkSecondary.color)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                if saved.id == chat?.id { startNewChat() }
                                store.delete(saved)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Chat lifecycle

    /// Binds the panel to a saved chat: the one handed in, the notebook's most
    /// recent, or a fresh one. A conversation that already has messages (a
    /// circle-to-explain that opened the sidebar) keeps them and gets a new chat.
    private func attachChat() async {
        guard chat == nil else { return }
        if !conversation.visibleMessages.isEmpty {
            chat = store.create(notebookID: notebookID)
            persist()
            return
        }
        if let existing = store.mostRecent(notebookID: notebookID) {
            chat = existing
            conversation.restore(turns: existing.turns)
        } else {
            chat = store.create(notebookID: notebookID)
        }
    }

    private func open(_ saved: NovaChat) {
        persist()
        chat = saved
        conversation.restore(turns: saved.turns)
        showHistory = false
    }

    private func startNewChat() {
        persist()
        conversation.reset()
        chat = store.create(notebookID: notebookID)
        showHistory = false
    }

    private func schedulePersist() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        guard let chat else { return }
        let turns = conversation.storedTurns
        guard !turns.isEmpty else { return }
        store.save(chat, turns: turns)
    }
}

/// One transcript row: the student's message as an accent bubble, NOVA's reply as
/// avatar + plain streaming text (ClassMate style — no assistant bubble).
struct NovaMessageRow: View {
    @Environment(\.theme) private var theme
    let message: AIMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: 6) {
                    if message.imageData != nil {
                        Label("From the page", systemImage: "lasso.badge.sparkles")
                            .font(.dsCaption2.weight(.semibold))
                            .foregroundStyle(theme.inkSecondary.color)
                    }
                    Text(message.content)
                        .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            theme.accent.color,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                NovaAvatar(size: 24)
                if message.content.isEmpty {
                    // A reply that has arrived but is still all reasoning: show a
                    // pulse, not an empty row.
                    NovaTypingDots()
                } else {
                    NovaMarkdownText(message.content)
                        .foregroundStyle(theme.ink.color)
                }
            }
        }
    }
}

/// Three breathing dots for the gap between "asked" and "the first word of the
/// answer" — with reasoning hidden, that gap is real, and a blank row looked broken.
struct NovaTypingDots: View {
    @Environment(\.theme) private var theme
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(theme.accent.color)
                    .frame(width: 6, height: 6)
                    .opacity(0.35 + 0.65 * pulse(index))
            }
        }
        .frame(height: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("NOVA is thinking")
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 3
            }
        }
    }

    private func pulse(_ index: Int) -> Double {
        let offset = (phase - Double(index)).truncatingRemainder(dividingBy: 3)
        return max(0, 1 - abs(offset - 0.5) * 1.6)
    }
}

/// The floating NOVA bubble every notebook carries. Draggable so it never sits on
/// top of what you're writing.
public struct NovaBubble: View {
    @Environment(\.theme) private var theme

    let isActive: Bool
    let action: () -> Void

    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    public init(isActive: Bool, action: @escaping () -> Void) {
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.accent.color)
                    .shadow(color: .black.opacity(0.26), radius: 12, y: 5)
                NovaAvatar(size: 30, animated: isActive)
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask NOVA")
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: dragStart.width + value.translation.width,
                        height: dragStart.height + value.translation.height
                    )
                }
                .onEnded { _ in dragStart = offset }
        )
    }
}
