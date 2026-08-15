import NotesDesignSystem
import NotesModels
import SwiftUI

/// The editor's navigation-bar buttons: bookmarks, the NOVA lasso, and the
/// overflow menu.
///
/// Its own file so `EditorScreen` stays under the size a screen is allowed to
/// be — the members it reads are internal on the struct for the same reason.
extension EditorScreen {
    /// The page a bookmark action would act on — the one being written on.
    var bookmarkTargetPage: PageRecord? {
        model.page(model.focusedPageID) ?? model.pages.first
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Flagging the page you're on is a one-tap thing; going through the
            // page manager to reach the page already in front of you isn't.
            if let page = bookmarkTargetPage {
                Button {
                    Task { await model.toggleBookmark(page.id) }
                } label: {
                    Image(systemName: page.isBookmarked ? "bookmark.fill" : "bookmark")
                }
                .tint(page.isBookmarked ? theme.accent.color : theme.ink.color)
                .accessibilityLabel(page.isBookmarked ? "Remove bookmark" : "Bookmark this page")
            }

            if !model.bookmarkedPages.isEmpty {
                Menu {
                    ForEach(model.bookmarkedPages) { page in
                        Button {
                            jump(to: page.id)
                        } label: {
                            Label(model.bookmarkLabel(for: page), systemImage: "bookmark")
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .accessibilityLabel("Go to a bookmark")
            }

            Button {
                explainMode.toggle()
            } label: {
                Image(systemName: "lasso.badge.sparkles")
            }
            .tint(explainMode ? theme.accent.color : theme.ink.color)
            .accessibilityLabel("Circle something for NOVA to explain")

            Menu {
                Button { Task { await recognizeHandwriting() } } label: {
                    Label("Handwriting → text", systemImage: "text.viewfinder")
                }
                Button {
                    pageSettings = settingsTargetPage
                } label: {
                    Label("Page settings", systemImage: "slider.horizontal.3")
                }
                Button { showFileImporter = true } label: {
                    Label("Import PDF / file", systemImage: "doc.badge.plus")
                }
                Button { showScanner = true } label: {
                    Label("Scan a document", systemImage: "doc.viewfinder")
                }
                Divider()
                Button { exportPDF() } label: {
                    Label("Export as PDF", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button {
                    Task { await model.setAllTape(hidden: true, on: nil) }
                } label: {
                    Label("Reveal all tape", systemImage: "eye")
                }
                Button {
                    Task { await model.setAllTape(hidden: false, on: nil) }
                } label: {
                    Label("Cover all tape", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }
}
