import ClassMateTheme
import SwiftUI

/// A themed notebook cover: cover color from the theme's cover palette, a
/// subtle spine, and a legible title. Content layer — opaque by design.
public struct NotebookCoverView: View {
    @Environment(\.theme) private var theme

    let title: String
    let coverColor: ThemeColor

    public init(title: String, coverColor: ThemeColor) {
        self.title = title
        self.coverColor = coverColor
    }

    public var body: some View {
        let ink = theme.contrastingInk(on: coverColor)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(coverColor.color.gradient)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.black.opacity(0.14))
                    .frame(width: 10)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 12,
                            bottomLeadingRadius: 12
                        )
                    )
            }
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(ink.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.leading, 20)
                    .padding([.bottom, .trailing], 12)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .accessibilityLabel("Notebook \(title)")
    }
}
