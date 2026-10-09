import ClassMateTheme
import NotesDesignSystem
import NotesEditor
import NotesLibrary
import NotesModels
import NotesServices
import SwiftUI

/// The routing layer — the ONLY code allowed to import NotesEditor.
///
/// Flow: launch animation → sign-in, unless the device is signed in or works
/// without an account → device root. iPad routes into the full editor; iPhone
/// into the read-only viewer and never touches editing code.
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
        // Said once, after the launch animation: notebooks put back in the
        // library, or a library rebuilt from the notebooks on disk.
        .alert(
            services.libraryNotice?.title ?? "",
            isPresented: Binding(
                get: { launchFinished && services.libraryNotice != nil },
                set: { if !$0 { services.libraryNotice = nil } }
            ),
            presenting: services.libraryNotice
        ) { _ in
            Button("OK") { services.libraryNotice = nil }
        } message: { notice in
            Text(notice.message)
        }
        // A sign-out the user didn't ask for (the session ended): the library
        // stayed open, and this says why sync and NOVA stopped.
        .alert(
            services.auth.signedOutNotice?.title ?? "",
            isPresented: Binding(
                get: {
                    launchFinished && services.libraryNotice == nil
                        && services.auth.signedOutNotice != nil
                },
                set: { if !$0 { services.auth.signedOutNotice = nil } }
            ),
            presenting: services.auth.signedOutNotice
        ) { _ in
            Button("OK") { services.auth.signedOutNotice = nil }
        } message: { notice in
            Text(notice.message)
        }
    }

    /// One branch for the library whether or not there is an account, so
    /// signing in from Settings doesn't rebuild the library under the sheet.
    @ViewBuilder
    private var content: some View {
        if services.auth.libraryIsOpen {
            deviceRoot
        } else if services.auth.state == .loading {
            ZStack {
                services.themeService.spec(prefersDark: systemScheme == .dark).surface.color
                    .ignoresSafeArea()
                BrandLoader(size: 64)
            }
        } else {
            LoginScreen()
        }
    }

    @ViewBuilder
    private var deviceRoot: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            LibraryTabScreen { notebook, pageID in
                // A remote-only notebook (created on another device, never
                // opened here) has no local ink package for the editor to
                // open — route it to the read-only viewer on every device,
                // iPad included, until real content sync exists. A notebook
                // the user explicitly marked View Only has real local ink —
                // it opens through the SAME local viewer the iPhone always
                // gets, not the remote-cache one.
                if notebook.isRemoteOnly {
                    RemoteNotebookViewerScreen(notebook: notebook)
                } else if notebook.isViewOnly {
                    NotebookViewerScreen(notebook: notebook, openingPage: pageID)
                } else {
                    EditorScreen(notebook: notebook, openingPage: pageID)
                }
            }
        } else {
            LibraryListScreen { notebook, pageID in
                if notebook.isRemoteOnly {
                    RemoteNotebookViewerScreen(notebook: notebook)
                } else {
                    NotebookViewerScreen(notebook: notebook, openingPage: pageID)
                }
            }
        }
    }
}
