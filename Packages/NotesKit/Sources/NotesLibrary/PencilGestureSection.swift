import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI

/// What the Apple Pencil's two gestures do.
///
/// Which pair of tools you want to flip between is personal — someone marking up
/// a reading wants the highlighter and the eraser, someone drawing diagrams wants
/// the ruler and the lasso — so the app asks instead of deciding. The choice is
/// stored with the rest of the settings, which means it follows the user to their
/// other device rather than being set up twice.
///
/// It lives in Settings, not in the editor's rail, because the iPhone has no rail
/// and the person holding the Pencil is on the iPad either way.
struct PencilGestureSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            picker(
                "Double-tap",
                systemImage: "hand.tap",
                selection: Binding(
                    get: { services.settings.tools.pencilDoubleTap },
                    set: { action in services.settings.update { $0.pencilDoubleTap = action } }
                )
            )
            picker(
                "Squeeze",
                systemImage: "hand.pinch",
                selection: Binding(
                    get: { services.settings.tools.pencilSqueeze },
                    set: { action in services.settings.update { $0.pencilSqueeze = action } }
                )
            )
        } header: {
            Text("Apple Pencil")
        } footer: {
            Text("Squeeze needs an Apple Pencil Pro. Double-tap works on Pencil 2 and later.")
                .font(.dsCaption)
                .foregroundStyle(theme.inkSecondary.color)
        }
        .listRowBackground(theme.surfaceRaised.color)
    }

    private func picker(
        _ title: String, systemImage: String, selection: Binding<PencilAction>
    ) -> some View {
        Picker(selection: selection) {
            ForEach(PencilAction.allCases) { action in
                Label(action.displayName, systemImage: action.symbolName).tag(action)
            }
        } label: {
            Label {
                Text(title).foregroundStyle(theme.ink.color)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(theme.accent.color)
            }
            .font(.dsBody)
        }
    }
}
