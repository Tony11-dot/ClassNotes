import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// First-use hints (`FirstUseHint`): one line, the first time a tool or panel
/// is reached, gone by itself after a few seconds.
extension EditorScreen {

    /// The hint for picking up `tool`, if it has one. Pen and eraser need no
    /// teaching.
    static func hint(for tool: ToolState.Tool) -> FirstUseHint? {
        switch tool {
        case .lasso: .lasso
        case .tape: .tape
        case .fill: .fill
        case .text, .codeBlock, .functionPlot: .text
        case .horizontalLine, .verticalLine: .ruledLine
        case .hand: .hand
        case .pen, .eraser: nil
        }
    }

    /// Shows `hint` if this device has never shown it.
    func offerHint(_ hint: FirstUseHint?) {
        guard let hint, FirstUseHints().claim(hint) else { return }
        withAnimation(.spring(duration: 0.3)) { activeHint = hint }
    }

    @ViewBuilder
    var hintBanner: some View {
        if let activeHint {
            HStack(spacing: 10) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(theme.accent.color)
                    .accessibilityHidden(true)
                Text(activeHint.message)
                    .font(.dsSubheadline.weight(.medium))
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Got it") {
                    withAnimation(.spring(duration: 0.3)) { self.activeHint = nil }
                }
                .font(.dsSubheadline.weight(.semibold))
                .foregroundStyle(theme.accent.color)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            .dsGlass(in: Capsule(), interactive: true)
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            .padding(.horizontal, 24)
            .padding(.top, editorNotice == nil ? 8 : 60)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .task(id: activeHint) {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.spring(duration: 0.3)) { self.activeHint = nil }
            }
        }
    }
}
