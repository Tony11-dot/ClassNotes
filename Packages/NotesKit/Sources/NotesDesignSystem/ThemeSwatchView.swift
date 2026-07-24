import ClassMateTheme
import SwiftUI

/// Live preview of a theme in the Settings list: paper card, accent dot,
/// surface field and ink strokes, all from the spec being previewed (not the
/// active environment theme).
public struct ThemeSwatchView: View {
    let spec: ThemeSpec

    public init(spec: ThemeSpec) {
        self.spec = spec
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(spec.surface.color)
            .overlay {
                HStack(spacing: 6) {
                    Circle()
                        .fill(spec.accent.color)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(spec.ink.color)
                            .frame(width: 34, height: 3)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(spec.inkSecondary.color)
                            .frame(width: 24, height: 3)
                    }
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(spec.paper.color)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(spec.separator.color, lineWidth: 0.5)
                        )
                        .frame(width: 18, height: 24)
                }
                .padding(.horizontal, 8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(spec.separator.color, lineWidth: 0.5)
            )
            .frame(width: 108, height: 44)
            .accessibilityLabel("\(spec.displayName) theme preview")
    }
}

/// Compact cover-palette dot row used by pickers.
public struct CoverPaletteRow: View {
    let palette: [ThemeColor]
    @Binding var selectedHex: String

    public init(palette: [ThemeColor], selectedHex: Binding<String>) {
        self.palette = palette
        self._selectedHex = selectedHex
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(palette.map(\.hexString), id: \.self) { hex in
                    let color = ThemeColor(hex: hex) ?? ThemeColor(red: 0, green: 0, blue: 0)
                    Button {
                        selectedHex = hex
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 30, height: 30)
                            .overlay {
                                if hex == selectedHex {
                                    Circle().strokeBorder(.white, lineWidth: 2)
                                    Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cover color \(hex)")
                }
            }
            .padding(.vertical, 4)
        }
    }
}
