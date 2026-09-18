import ClassMateTheme
import NotesDesignSystem
import SwiftUI

/// The copied region, waiting to be put back down.
extension EditorScreen {
    /// The copied region, waiting to be put back down — floated right next to
    /// WHERE it was copied from, on the page it belongs to.
    ///
    /// This used to be a fixed bottom-leading overlay pinned beside the tool
    /// rail, on screen the whole time a snip was in hand regardless of where
    /// that snip actually came from — which reads as a permanent extra rail
    /// button rather than something tied to the copy the user just made. A
    /// snapshot that only ever leaves for another app is half a Copy: press
    /// this and the picture lands back on the page as a thing you can drag and
    /// pinch, and the editor switches to Move so it is adjustable the moment
    /// it arrives.
    @ViewBuilder
    func pasteChip(near frame: CGRect, in displaySize: CGSize) -> some View {
        if let snip = copiedSnip {
            let chipWidth: CGFloat = 96
            let x = min(max(frame.midX, chipWidth / 2 + 8), displaySize.width - chipWidth / 2 - 8)
            let below = frame.maxY + 30
            let y = below + 22 <= displaySize.height ? below : max(22, frame.minY - 30)
            Button {
                Task { await pasteSnip() }
            } label: {
                HStack(spacing: 8) {
                    Image(uiImage: snip.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
            .position(x: x, y: y)
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
