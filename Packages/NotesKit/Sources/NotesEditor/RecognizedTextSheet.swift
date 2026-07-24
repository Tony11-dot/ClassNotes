import ClassMateTheme
import NotesDesignSystem
import SwiftUI

/// Shows handwriting recognized into text and lets the user pick the font to
/// re-typeset it in before dropping it on the page (not a plain textbox — a
/// styled text element).
struct RecognizedTextSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let text: String
    let onInsert: (String, String) -> Void

    @State private var edited: String
    @State private var fontChoice: FontChoice = .cabinet

    init(text: String, onInsert: @escaping (String, String) -> Void) {
        self.text = text
        self.onInsert = onInsert
        self._edited = State(initialValue: text)
    }

    enum FontChoice: String, CaseIterable, Identifiable {
        case cabinet = "CabinetGrotesk-Regular"
        case system = "system"
        case marker = "MarkerFelt-Thin"
        case noteworthy = "Noteworthy"
        case bradley = "BradleyHandITCTT-Bold"
        case snell = "SnellRoundhand"
        case georgia = "Georgia"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .cabinet: "Cabinet Grotesk"
            case .system: "System"
            case .marker: "Marker"
            case .noteworthy: "Noteworthy"
            case .bradley: "Bradley Hand"
            case .snell: "Snell Roundhand"
            case .georgia: "Georgia"
            }
        }
        var font: Font {
            self == .system ? .system(size: 20) : .custom(rawValue, size: 20)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recognized text") {
                    TextEditor(text: $edited)
                        .frame(minHeight: 120)
                        .font(fontChoice.font)
                }
                Section("Font") {
                    Picker("Font", selection: $fontChoice) {
                        ForEach(FontChoice.allCases) { choice in
                            Text(choice.label).font(choice.font).tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Text(edited)
                        .font(fontChoice.font)
                        .foregroundStyle(theme.ink.color)
                } header: {
                    Text("Preview")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("Handwriting → text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to page") {
                        onInsert(edited, fontChoice.rawValue)
                        dismiss()
                    }
                    .disabled(edited.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
