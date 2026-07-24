import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// Create a shelf (a bag / book / folder) to group notebooks.
struct NewShelfSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var symbol: ShelfSymbol = .bag
    @State private var colorHex = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Biology, Journal, Sketchbook…", text: $name)
                }
                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 12) {
                        ForEach(ShelfSymbol.allCases, id: \.self) { option in
                            Image(systemName: option.systemName)
                                .font(.title2)
                                .foregroundStyle(symbol == option ? theme.accent.color : theme.inkSecondary.color)
                                .frame(width: 48, height: 48)
                                .background(
                                    symbol == option ? theme.accentMuted.color : theme.surfaceRaised.color,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .onTapGesture { symbol = option }
                        }
                    }
                }
                Section("Color") {
                    CoverPaletteRow(palette: theme.coverPalette, selectedHex: $colorHex)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("New Shelf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        try? services.repository.createShelf(
                            name: name,
                            colorHex: colorHex.isEmpty ? theme.accent.hexString : colorHex,
                            symbolName: symbol.systemName
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { if colorHex.isEmpty { colorHex = theme.accent.hexString } }
    }
}
