import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// The "known graphs" picker `FunctionPlotSettingsSheet` opens: e^x, sin(x), a
/// v-t line, O(n log n) — filterable by subject, with whatever the user has
/// actually picked before surfaced under Recent instead of making them retype
/// an expression they've already used.
struct GraphPresetPickerSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let recentIDs: [String]
    let onSelect: (GraphPreset) -> Void

    @State private var subject: GraphSubject?

    private var recentPresets: [GraphPreset] {
        recentIDs.compactMap(GraphPresetLibrary.preset(id:))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("Subject", selection: $subject) {
                        Text("All").tag(GraphSubject?.none)
                        ForEach(GraphSubject.allCases) { candidate in
                            Text(candidate.displayName).tag(GraphSubject?.some(candidate))
                        }
                    }
                    .pickerStyle(.segmented)

                    if subject == nil, !recentPresets.isEmpty {
                        section(title: "Recent", systemImage: "clock", presets: recentPresets)
                    }
                    ForEach(GraphSubject.allCases) { candidate in
                        if subject == nil || subject == candidate {
                            section(
                                title: candidate.displayName, systemImage: candidate.symbolName,
                                presets: GraphPresetLibrary.presets(for: candidate)
                            )
                        }
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("Known Graphs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large, .medium])
    }

    private func section(title: String, systemImage: String, presets: [GraphPreset]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.dsHeadline)
                .foregroundStyle(theme.ink.color)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                ForEach(presets) { preset in
                    Button {
                        onSelect(preset)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name)
                                .font(.dsSubheadline.weight(.semibold))
                                .foregroundStyle(theme.ink.color)
                            Text(preset.mode == .parametric
                                 ? "x(t)=\(preset.expression)"
                                 : preset.expression)
                                .font(.dsCaption.monospaced())
                                .foregroundStyle(theme.inkSecondary.color)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
