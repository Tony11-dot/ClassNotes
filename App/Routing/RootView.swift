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
                NotebookRoute(notebook: notebook, pageID: pageID, canEdit: true)
            }
        } else {
            LibraryListScreen { notebook, pageID in
                NotebookRoute(notebook: notebook, pageID: pageID, canEdit: false)
            }
        }
    }
}

/// Where opening a notebook goes, decided INSIDE a view of its own so it is
/// decided again when the notebook changes under it: "Edit on this iPad" and
/// "Make Editable" clear a flag, and the screen becomes the editor in place.
/// Read in the library's destination closure, the flags were read once, and
/// the user was left looking at a viewer for a notebook that could now be
/// edited.
///
/// A remote-only notebook (written on another device, with no ink package
/// here) shows the server's pictures of its pages; the iPad can bring it over.
/// A notebook the user marked View Only has real local ink and opens in the
/// SAME local viewer the iPhone always gets. The iPhone never edits.
private struct NotebookRoute: View {
    let notebook: Notebook
    let pageID: UUID?
    let canEdit: Bool

    var body: some View {
        if notebook.isRemoteOnly {
            RemoteNotebookViewerScreen(notebook: notebook, allowsEditing: canEdit)
        } else if !canEdit || notebook.isViewOnly {
            NotebookViewerScreen(notebook: notebook, openingPage: pageID, allowsEditing: canEdit)
        } else {
            EditorScreen(notebook: notebook, openingPage: pageID)
        }
    }
}
