import ClassMateTheme
import SwiftUI

/// A horizontal palette of paper colors: "Auto" (theme paper), the curated
/// `PaperPalette` stocks, and a `+` into the color wheel for anything else. Binds
/// the selected hex (`nil` == auto). Shared by New Notebook and per-page settings.
public struct PaperSwatchRow: View {
    @Binding var selection: String?

    public init(selection: Binding<String?>) {
        self._selection = selection
    }

    public var body: some View {
        ColorSwatchRow(
            swatches: PaperPalette.all.map(\.color.hexString),
            selection: $selection,
            includesAuto: true
        )
    }
}

/// The rule / grid / dot color row: "Auto" (theme separator), the classic line
/// colors, and the color wheel.
public struct LineColorRow: View {
    @Binding var selection: String?

    public init(selection: Binding<String?>) {
        self._selection = selection
    }

    public var body: some View {
        ColorSwatchRow(
            swatches: PaperPalette.lineColors.map(\.color.hexString),
            selection: $selection,
            includesAuto: true
        )
    }
}
