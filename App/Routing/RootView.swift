import ClassMateTheme
import NotesDesignSystem
import NotesEditor
import NotesLibrary
import NotesModels
import NotesServices
import SwiftUI

/// The routing layer — the ONLY code allowed to import NotesEditor.
/// iPad routes into the full editor; iPhone routes into the read-only viewer
/// and never touches editing code.
struct RootView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let prefersDark = systemScheme == .dark
        let spec = services.themeService.spec(prefersDark: prefersDark)
        deviceRoot
            .environment(\.theme, spec)
            .environment(\.paperTone, services.themeService.paperTone)
            .tint(spec.accent.color)
            .preferredColorScheme(
                services.themeService.pinnedDarkMode(prefersDark: prefersDark)
                    .map { $0 ? .dark : .light }
            )
    }

    @ViewBuilder
    private var deviceRoot: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            LibraryGridScreen { notebook in
                EditorScreen(notebook: notebook)
            }
        } else {
            LibraryListScreen { notebook in
                NotebookViewerScreen(notebook: notebook)
            }
        }
    }
}
