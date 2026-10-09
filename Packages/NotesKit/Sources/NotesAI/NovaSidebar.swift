import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI
import UIKit

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
    /// Renders the whole notebook down to one contact-sheet image, and hands
    /// over where its pages' text comes from, for the "Read notebook" button.
    /// Nil hides the button — `NovaSidebar` itself only knows the notebook's
    /// id, not how to render its pages, so whoever presents it (the editor,
    /// which already has the notebook and the document store) supplies this.
    private let onReadNotebook: (() async -> NovaNotebookReading?)?
    /// Opens a page by the number the app shows it under (0 is the cover),
    /// for the page links under an answer that cites the notes.
    private let onOpenPage: ((Int) -> Void)?

    @State private var chat: NovaChat?
    @State private var draft = ""
    @State private var showHistory = false
    /// Non-nil while the composer holds an edited copy of a message the user
    /// already sent, rather than a brand-new one.
    @State private var editingMessageID: UUID?
    /// Debounces transcript writes while a reply streams in token by token.
    @State private var saveTask: Task<Void, Never>?
    @State private var readingNotebook = false

    public init(
        conversation: NovaConversation,
        store: NovaChatStore,
        notebookID: UUID?,
        chat: NovaChat? = nil,
        onReadNotebook: (() async -> NovaNotebookReading?)? = nil,
        onOpenPage: ((Int) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.store = store
        self.notebookID = notebookID
        self.onReadNotebook = onReadNotebook
        self.onOpenPage = onOpenPage
        self.onClose = onClose
        _chat = State(initialValue: chat)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if conversation.notebook != nil, !showHistory {
                NovaNotebookChip { conversation.stopReadingNotebook() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
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
            if let onReadNotebook {
                Button {
                    readNotebook(using: onReadNotebook)
                } label: {
                    if readingNotebook {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.ink.color)
                .disabled(readingNotebook || conversation.streaming)
                .accessibilityLabel("Read this notebook")
                .help("Have NOVA read every page of this notebook")
            }
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
                        NovaTranscriptEntry(
                            message: message,
                            conversation: conversation,
                            onEdit: message.role == .user ? { beginEditing(message) } : nil,
                            onOpenPage: onOpenPage
                        )
                        .id(message.id)
                        if message.id == lastAssistantReplyID, !conversation.streaming,
                           !conversation.followUpSuggestions.isEmpty {
                            NovaFollowUpRow(conversation: conversation)
                        }
                    }
                    if conversation.awaitingConsent {
                        NovaConsentCard(conversation: conversation, draft: $draft).id("nova-consent")
                    }
                    if let error = conversation.errorText {
                        Text(error).font(.dsFootnote).foregroundStyle(.red)
                            .id("nova-error")
                    }
                }
                .padding(16)
            }
            .onChange(of: conversation.visibleMessages.last?.content) { _, _ in
                if let last = conversation.visibleMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // A failure removes the empty assistant placeholder (see
            // `removeEmptyAssistant`), so `visibleMessages.last` reverts to
            // whatever the user already sent — its content hasn't changed,
            // so the `onChange` above never fires and the error line lands
            // below the fold with nothing to scroll to it. That is "NOVA
            // couldn't respond" reading as NOVA doing nothing at all: the
            // real answer was on screen, just not in view.
            .onChange(of: conversation.errorText) { _, error in
                guard error != nil else { return }
                withAnimation { proxy.scrollTo("nova-error", anchor: .bottom) }
            }
            .onChange(of: conversation.awaitingConsent) { _, waiting in
                guard waiting else { return }
                withAnimation { proxy.scrollTo("nova-consent", anchor: .bottom) }
            }
        }
    }

    /// The last message in the transcript, when it's a finished assistant
    /// reply — where the follow-up chips go.
    private var lastAssistantReplyID: UUID? {
        guard let last = conversation.visibleMessages.last, last.role == .assistant,
              !last.content.isEmpty else { return nil }
        return last.id
    }

    private func readNotebook(using render: @escaping () async -> NovaNotebookReading?) {
        readingNotebook = true
        Task {
            defer { readingNotebook = false }
            guard let reading = await render() else { return }
            conversation.explainNotebook(
                image: reading.image, pageCount: reading.pageCount, source: reading.source
            )
        }
    }

    private func beginEditing(_ message: AIMessage) {
        editingMessageID = message.id
        draft = message.content
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
        VStack(alignment: .leading, spacing: 0) {
            if editingMessageID != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil").font(.dsCaption2)
                    Text("Editing message").font(.dsCaption2.weight(.medium))
                    Spacer()
                    Button {
                        editingMessageID = nil
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel edit")
                }
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
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
                    send()
                } label: {
                    Image(systemName: editingMessageID != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.dsSystem(size: 30))
                        .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || conversation.streaming)
                .accessibilityLabel(editingMessageID != nil ? "Save edit" : "Send")
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }

    private func send() {
        if let editingMessageID {
            conversation.editUserMessage(id: editingMessageID, newText: draft)
            self.editingMessageID = nil
        } else {
            conversation.send(draft)
        }
        draft = ""
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
                        // Press and hold reaches the same actions as the swipe:
                        // the row lifts, the list behind it blurs, and the
                        // actions drop out under it.
                        .contextMenu {
                            Button(role: .destructive) {
                                if saved.id == chat?.id { startNewChat() }
                                store.delete(saved)
                            } label: {
                                Label("Delete chat", systemImage: "trash")
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
    /// Non-nil (user messages only) puts the composer into edit mode for this
    /// message on tap or from its context menu.
    var onEdit: (() -> Void)?

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
            .contentShape(Rectangle())
            .onTapGesture { onEdit?() }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let onEdit {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
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
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
        }
    }
}
