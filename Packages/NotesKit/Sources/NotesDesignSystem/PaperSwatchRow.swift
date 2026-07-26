import ClassMateTheme
import SwiftUI

/// A horizontal palette of paper colors: "Auto" (theme paper) plus the curated
/// `PaperPalette` stocks (cream/white/black + shades). Binds the selected hex
/// (`nil` == auto). Shared by New Notebook and per-page settings.
public struct PaperSwatchRow: View {
    @Environment(\.theme) private var theme
    @Binding var selection: String?

    private let swatchSize: CGFloat = 34

    public init(selection: Binding<String?>) {
        self._selection = selection
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                autoSwatch
                ForEach(PaperPalette.all) { swatch in
                    swatchView(hex: swatch.color.hexString, name: swatch.name)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var autoSwatch: some View {
        Button { selection = nil } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(theme.paperColor(tone: .neutral).color)
                    Image(systemName: "a.circle").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.inkSecondary.color)
                }
                .frame(width: swatchSize, height: swatchSize)
                .overlay(ring(isSelected: selection == nil))
                Text("Auto").font(.caption2).foregroundStyle(theme.inkSecondary.color)
            }
        }
        .buttonStyle(.plain)
    }

    private func swatchView(hex: String, name: String) -> some View {
        let isSelected = selection?.caseInsensitiveCompare(hex) == .orderedSame
        return Button { selection = hex } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(ThemeColor(hex: hex)?.color ?? .white)
                    .frame(width: swatchSize, height: swatchSize)
                    .overlay(Circle().strokeBorder(theme.separator.color, lineWidth: 0.5))
                    .overlay(ring(isSelected: isSelected))
                Text(name).font(.caption2).foregroundStyle(theme.inkSecondary.color)
                    .lineLimit(1)
            }
            .frame(width: 54)
        }
        .buttonStyle(.plain)
    }

    private func ring(isSelected: Bool) -> some View {
        Circle().strokeBorder(theme.accent.color, lineWidth: isSelected ? 2.5 : 0)
            .padding(-3)
    }
}
