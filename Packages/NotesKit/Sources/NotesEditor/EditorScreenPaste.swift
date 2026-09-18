import ClassMateTheme
import NotesDesignSystem
import NotesModels
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
            HStack(spacing: 0) {
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
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .frame(height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste the copied region")

                Divider().frame(height: 20)

                // A direct X, not a press-and-hold context menu: holding to
                // discover "Discard" buried a one-tap change of mind behind a
                // gesture nothing else on the chip hinted was there.
                Button {
                    withAnimation(.spring(duration: 0.25)) { copiedSnip = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.dsSubheadline.weight(.semibold))
                        .foregroundStyle(theme.inkSecondary.color)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard the copied region")
            }
            .dsGlass(in: Capsule(), interactive: true)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .position(x: x, y: y)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// The Confirm/Discard bar over a just-pasted element, while
    /// `pendingPasteElementID` still names it. Mirrors `LassoSelectionView`'s
    /// own actions bar — same shape, same "Done" checkmark — because this is
    /// the same idea one step later: adjust the thing you just brought onto
    /// the page, then say you're finished with it.
    @ViewBuilder
    func pastePendingActions(
        for element: PageElement, on pageID: UUID, displaySize: CGSize, logicalSize: CGSize
    ) -> some View {
        if logicalSize.width > 0 {
            let scale = displaySize.width / logicalSize.width
            let frame = CGRect(
                x: element.x * scale, y: element.y * scale,
                width: element.width * scale, height: element.height * scale
            )
            let barWidth: CGFloat = 96
            let x = min(max(frame.midX, barWidth / 2 + 8), displaySize.width - barWidth / 2 - 8)
            let above = frame.minY - 30
            let y = above >= 22 ? above : min(displaySize.height - 22, frame.maxY + 30)
            HStack(spacing: 2) {
                pastePendingAction("Discard", systemImage: "xmark", destructive: true) {
                    Task { await discardPendingPaste(element, on: pageID) }
                }
                pastePendingAction("Confirm", systemImage: "checkmark", perform: confirmPendingPaste)
            }
            .padding(.horizontal, 6)
            .frame(height: 40)
            .dsGlass(in: Capsule(), interactive: true)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .position(x: x, y: y)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func pastePendingAction(
        _ title: String, systemImage: String, destructive: Bool = false, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: systemImage)
                .font(.dsSystem(size: 15, weight: .medium))
                .foregroundStyle(destructive ? Color.red : theme.ink.color)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
