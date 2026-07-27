import SwiftUI

/// Themed empty state for the library and anywhere else content can be absent.
public struct EmptyStateView: View {
    @Environment(\.theme) private var theme

    let systemImage: String
    let title: String
    let message: String

    public init(systemImage: String, title: String, message: String) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.dsSystem(size: 44, weight: .light))
                .foregroundStyle(theme.accent.color)
            Text(title)
                .font(.dsTitle3.weight(.semibold))
                .foregroundStyle(theme.ink.color)
            Text(message)
                .font(.dsSubheadline)
                .foregroundStyle(theme.inkSecondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }
}
