import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// The two things the editor says about the user's work itself: that a save
/// didn't land (and that what's on screen is still there), and that pages were
/// just deleted (with the Undo that brings them back).
extension EditorScreen {

    /// The first save problem from either half of the document — ink, or the
    /// manifest and its elements. Shown until the retry lands.
    var currentSaveProblem: SaveProblem? {
        tracker.saveProblem ?? model.saveProblem
    }

    @ViewBuilder
    var saveProblemBanner: some View {
        if let problem = currentSaveProblem {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: problem.isOutOfSpace ? "externaldrive.badge.exclamationmark" : "exclamationmark.icloud")
                    .font(.dsTitle3)
                    .foregroundStyle(theme.accent.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(problem.title)
                        .font(.dsSubheadline.weight(.semibold))
                        .foregroundStyle(theme.ink.color)
                    Text(problem.message)
                        .font(.dsFootnote)
                        .foregroundStyle(theme.inkSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 520, alignment: .leading)
            .dsGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    /// A running import's progress. The editor stays usable underneath it —
    /// the import renders off the main thread and off the document's own
    /// queue, so writing carries on and saves as normal.
    @ViewBuilder
    var importProgressPill: some View {
        if let progress = model.importProgress {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.total > 0
                     ? "Importing page \(progress.done) of \(progress.total)…"
                     : "Importing…")
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .dsGlass(in: Capsule())
            .padding(.top, 8)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    /// "Page deleted — Undo", for long enough to notice the wrong page went.
    /// Gone after a few seconds; the pages stay in Recently Deleted.
    @ViewBuilder
    var deletedPagesToast: some View {
        let count = model.recentlyDeletedPages.count
        if count > 0 {
            HStack(spacing: 14) {
                Image(systemName: "trash")
                    .foregroundStyle(theme.inkSecondary.color)
                Text(count == 1 ? "Page deleted" : "\(count) pages deleted")
                    .font(.dsSubheadline.weight(.medium))
                    .foregroundStyle(theme.ink.color)
                Button {
                    Task { await model.undoRecentDeletion() }
                } label: {
                    Text("Undo")
                        .font(.dsSubheadline.weight(.bold))
                        .foregroundStyle(theme.accent.color)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Puts the deleted pages back where they were")
            }
            .padding(.leading, 18).padding(.trailing, 8)
            .dsGlass(in: Capsule(), interactive: true)
            .padding(.bottom, 64)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: model.recentlyDeletedPages) {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                model.dismissRecentDeletion()
            }
        }
    }
}

// MARK: - Sending pages to another notebook

extension EditorScreen {

    func pageDestinations() -> [PageDestination] {
        services.repository.pageDestinations(excluding: notebook.id).map {
            PageDestination(id: $0.id, title: $0.title, colorHex: $0.coverColorHex)
        }
    }

    func sendPages(
        _ pages: Set<UUID>, model: NotebookEditorModel, to destination: PageDestination, move: Bool
    ) async {
        // The newest strokes first: a page sent while its save is still
        // debouncing would otherwise arrive without them.
        await tracker.flushAllPendingSavesAndWait()
        guard let count = await model.transferPages(pages, to: destination.id, move: move) else { return }
        services.repository.pagesArrived(in: destination.id)
        let what = count == 1 ? "1 page" : "\(count) pages"
        if count == 0 {
            editorNotice = "The cover stays with its own notebook, so nothing was sent."
        } else if move {
            editorNotice = "Moved \(what) to \(destination.title). The originals are in Recently Deleted."
        } else {
            editorNotice = "Copied \(what) to \(destination.title)."
        }
    }
}
