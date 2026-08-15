import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// The two big rectangles at the top of New Notebook: the cover as it will look,
/// and the paper as it will look.
///
/// Split from the sheet itself only so neither file is the 350-line type nobody
/// wants to open; the members it reads are internal for the same reason.
extension NewNotebookSheet {
    // MARK: - Previews (two big rectangles, side by side)

    var previewRow: some View {
        HStack(alignment: .top, spacing: 16) {
            if kind != .whiteboard { coverPreview }
            paperPreview
        }
        .frame(maxWidth: .infinity)
    }

    /// The cover, in the same big rectangular card as the paper preview — the two
    /// entry buttons now match instead of the cover floating loose beside it.
    var coverPreview: some View {
        Button {
            showCoverPicker = true
        } label: {
            previewCard(
                title: coverDesign.displayName,
                caption: "Cover",
                accessory: "chevron.right"
            ) {
                NotebookCoverView(
                    title: previewTitle, coverColor: coverColor,
                    design: coverDesign, showsTitle: showsCover
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cover: \(coverDesign.displayName). Tap to change.")
    }

    var paperPreview: some View {
        previewCard(title: style.template.displayName, caption: "Template") {
            PageTemplateView(style: style)
                .aspectRatio(PageTemplateView.aspectRatio(of: style), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.separator.color, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
    }

    /// One preview rectangle: the art centred in a fixed-height well, then a
    /// single-line name and caption. Both cards are the same size whatever they
    /// hold, and long names shrink rather than wrapping onto a second line.
    func previewCard<Content: View>(
        title: String,
        caption: String,
        accessory: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 10) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 190)
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.dsSubheadline.weight(.semibold))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(caption)
                        .font(.dsCaption)
                        .foregroundStyle(theme.inkSecondary.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let accessory {
                    Image(systemName: accessory)
                        .font(.dsCaption.weight(.bold))
                        .foregroundStyle(theme.inkSecondary.color)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
