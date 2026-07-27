import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// The cover gallery: every `CoverDesign`, grouped from plain stocks to decorated
/// ones, over any colour from the theme palette, the bookbinding stocks, or the
/// colour wheel. Each chip is the real cover renderer, so a chip is exactly what
/// the library will show.
struct CoverDesignPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @Binding var design: CoverDesign
    @Binding var colorHex: String?
    let title: String

    init(design: Binding<CoverDesign>, colorHex: Binding<String>, title: String) {
        self._design = design
        // The sheet shares the caller's non-optional hex through an optional
        // binding, because that's the shape the colour row speaks.
        self._colorHex = Binding(
            get: { colorHex.wrappedValue },
            set: { colorHex.wrappedValue = $0 ?? colorHex.wrappedValue }
        )
        self.title = title
    }

    private var coverColor: ThemeColor {
        colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accent
    }

    /// Theme accents first (so covers match the app), then real book stocks.
    private var palette: [String] {
        var seen = Set<String>()
        return (theme.coverPalette.map(\.hexString)
            + PaperPalette.coverStocks.map(\.color.hexString))
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            // One scroll, header included — pinned above the gallery, the preview
            // and its colour row got squeezed on a short window.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().overlay(theme.separator.color)
                    gallery
                }
            }
            .background(theme.surface.color)
            .navigationTitle("Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            NotebookCoverView(title: title, coverColor: coverColor, design: design)
                .frame(width: 108)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 8) {
                Text(design.displayName)
                    .font(.dsTitle3.weight(.bold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(design.category.displayName)
                    .font(.dsSubheadline)
                    .foregroundStyle(theme.inkSecondary.color)
                    .lineLimit(1)
                Text("Colour")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(theme.inkSecondary.color)
                ColorSwatchRow(swatches: palette, selection: $colorHex)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(CoverDesign.Category.allCases) { category in
                VStack(alignment: .leading, spacing: 12) {
                    Text(category.displayName)
                        .font(.dsHeadline)
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 96, maximum: 132), spacing: 18)],
                        spacing: 18
                    ) {
                        ForEach(category.designs) { option in
                            chip(option)
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private func chip(_ option: CoverDesign) -> some View {
        let isSelected = design == option
        return Button {
            design = option
        } label: {
            VStack(spacing: 8) {
                NotebookCoverView(title: title, coverColor: coverColor, design: option)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isSelected ? theme.accent.color : .clear,
                                lineWidth: 3
                            )
                    )
                    .shadow(color: .black.opacity(isSelected ? 0.2 : 0.1), radius: 7, y: 3)
                Text(option.displayName)
                    .font(.dsCaption)
                    .foregroundStyle(isSelected ? theme.ink.color : theme.inkSecondary.color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
