import ClassMateTheme
import NotesDesignSystem
import SwiftUI

/// The copied region, waiting to be put back down.
extension EditorScreen {
    /// The copied region, waiting to be put back down.
    ///
    /// A snapshot that only ever leaves for another app is half a Copy. This is
    /// the other half: press it and the picture lands on the page as a thing you
    /// can drag and pinch, and the editor switches to Move so it is adjustable the
    /// moment it arrives.
    @ViewBuilder
    var pasteChip: some View {
        if copiedSnip != nil {
            Button {
                Task { await pasteSnip() }
            } label: {
                HStack(spacing: 8) {
                    if let snip = copiedSnip {
                        Image(uiImage: snip)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text("Paste")
                        .font(.dsSubheadline.weight(.semibold))
                        .foregroundStyle(theme.ink.color)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .dsGlass(in: Capsule(), interactive: true)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.leading, 110)
            .padding(.bottom, 18)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Paste the copied region")
            .contextMenu {
                Button(role: .destructive) { copiedSnip = nil } label: {
                    Label("Discard", systemImage: "trash")
                }
            }
        }
    }
}
