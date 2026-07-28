import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI
import UIKit

/// A notebook's cover as the library shows it.
///
/// The cover is page one of the document, so the shelf has to show what's
/// actually ON it: this loads the render the editor saves beside the pages
/// (`cover.png`) and falls back to the procedural artwork until one exists — a
/// notebook that has never been opened, or one whose cover switch is off.
///
/// Reloaded whenever the row's `updatedAt` moves: leaving the editor writes a
/// fresh render and then touches the row, which is exactly that signal.
public struct NotebookCoverTile: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    let notebook: Notebook
    /// Whether the FALLBACK artwork carries the title. A saved render always shows
    /// as it was drawn — it's the real cover.
    let showsTitle: Bool

    @State private var render: UIImage?

    public init(notebook: Notebook, showsTitle: Bool = true) {
        self.notebook = notebook
        self.showsTitle = showsTitle
    }

    public var body: some View {
        NotebookCoverView(
            title: notebook.title,
            coverColor: ThemeColor(hex: notebook.coverColorHex) ?? theme.accent,
            design: notebook.coverDesign,
            showsTitle: showsTitle && notebook.showsCover,
            render: render
        )
        .task(id: reloadKey) { await loadRender() }
    }

    /// Identity for the reload: the notebook, and the last time anything about it
    /// changed.
    private var reloadKey: String {
        "\(notebook.id.uuidString)-\(notebook.updatedAt.timeIntervalSince1970)"
    }

    private func loadRender() async {
        guard notebook.usesCoverPage else {
            render = nil
            return
        }
        let data = await services.documentStore.coverImageData(for: notebook.id)
        render = data.flatMap { UIImage(data: $0) }
    }
}
