import ClassMateTheme
import NotesDesignSystem
import NotesEditor
import NotesLibrary
import NotesModels
import NotesServices
import SwiftUI

/// The routing layer — the ONLY code allowed to import NotesEditor.
///
/// Flow: launch animation → auth gate (ClassMate sign-in) → device root. iPad
/// routes into the full editor; iPhone into the read-only viewer and never
/// touches editing code.
struct RootView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var systemScheme

    @State private var launchFinished = false

    var body: some View {
        let prefersDark = systemScheme == .dark
        let spec = services.themeService.spec(prefersDark: prefersDark)

        ZStack {
            content
            if !launchFinished {
                LaunchView { launchFinished = true }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .environment(\.theme, spec)
        .environment(\.paperTone, services.themeService.paperTone)
        .tint(spec.accent.color)
        .preferredColorScheme(
            services.themeService.pinnedDarkMode(prefersDark: prefersDark)
                .map { $0 ? .dark : .light }
        )
        .animation(.easeInOut(duration: 0.3), value: launchFinished)
    }

    @ViewBuilder
    private var content: some View {
        switch services.auth.state {
        case .loading:
            Color.clear
        case .signedOut:
            LoginScreen()
        case .authenticated:
            deviceRoot
        }
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
