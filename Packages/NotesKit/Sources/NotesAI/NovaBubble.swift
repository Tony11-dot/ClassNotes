import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

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
        ZStack {
            Circle()
                .fill(theme.accent.color)
                .shadow(color: .black.opacity(0.26), radius: 12, y: 5)
            NovaAvatar(size: 30, animated: isActive)
        }
        .frame(width: 56, height: 56)
        .contentShape(Circle())
        .accessibilityLabel("Ask NOVA")
        .accessibilityAddTraits(.isButton)
        .offset(offset)
        // A plain view rather than a `Button`, because a Button's own press
        // gesture wins the touch and only yields once SwiftUI decides the drag
        // has begun — so the bubble sat still under the finger and then flicked
        // to the release point. Here the drag is the primary gesture and the tap
        // is what happens when the finger didn't travel.
        .highPriorityGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    offset = CGSize(
                        width: dragStart.width + value.translation.width,
                        height: dragStart.height + value.translation.height
                    )
                }
                .onEnded { _ in dragStart = offset }
        )
        .onTapGesture { action() }
        // The drag owns the touch, so VoiceOver's activate is wired directly.
        .accessibilityAction { action() }
    }
}

/// What "Read this notebook" hands NOVA: a contact sheet of every page, and
/// where the pages' text comes from for each later question.
public struct NovaNotebookReading {
    public let image: Data
    public let pageCount: Int
    public let source: NovaNotebookSource

    public init(image: Data, pageCount: Int, source: NovaNotebookSource) {
        self.image = image
        self.pageCount = pageCount
        self.source = source
    }
}

/// Tappable follow-ups under NOVA's latest reply, generated from the real
/// conversation (`NovaConversation.followUpSuggestions`) rather than a fixed
/// list — no backend change needed, since generation reuses the same
/// chat-completion path a typed message already goes through.
struct NovaFollowUpRow: View {
    @Environment(\.theme) private var theme
    let conversation: NovaConversation

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(conversation.followUpSuggestions, id: \.self) { suggestion in
                    Button {
                        conversation.send(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.dsCaption.weight(.medium))
                            .foregroundStyle(theme.accent.color)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(theme.accentMuted.withAlpha(0.16).color, in: Capsule())
                            .overlay(Capsule().strokeBorder(theme.accent.withAlpha(0.3).color, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 34) // clears the avatar column above it
        }
        .disabled(conversation.streaming)
    }
}
