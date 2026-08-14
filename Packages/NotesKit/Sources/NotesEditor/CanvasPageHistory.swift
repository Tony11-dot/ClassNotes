import NotesModels
import PencilKit
import UIKit

/// The page's own undo history.
///
/// Split out of the coordinator's own file because it is a self-contained
/// machine: whole-drawing snapshots, one step per settled change, each step
/// registering its mirror image as it is undone so Redo needs no second stack.
extension CanvasPageView.Coordinator {
    // MARK: - The page's history

    /// Closes the change in progress as one step on the page's stack.
    ///
    /// Steps are whole snapshots rather than deltas. A page's ink is a few tens
    /// of kilobytes and a step happens when the hand rests, so the cost is
    /// nothing next to being able to state exactly what Undo does: it puts the
    /// page back the way it was.
    func commitUndoStep(named name: String = "Draw") {
        commitTask?.cancel()
        guard hasUncommittedChange, !isUsingTool, !isPencilDown,
              let canvas = canvas as? PageCanvasView else { return }
        let previous = undoBaseline
        let next = canvas.drawing
        hasUncommittedChange = false
        undoBaseline = next
        guard Self.differ(previous, next) else { return }
        pushStep(
            restoring: previous, elements: nil,
            counterDrawing: next, counterElements: nil,
            named: name, on: canvas
        )
        tracker.undoStackChanged()
    }

    func scheduleUndoCommit() {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.commitUndoStep()
        }
    }

    /// A cheap "did anything actually change?". Exact comparison would mean
    /// serializing the whole page on every settle; count and extent catch every
    /// change a user can make with a pencil.
    static func differ(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
        lhs.strokes.count != rhs.strokes.count || lhs.bounds != rhs.bounds
    }

    /// One step, in both directions. Undoing it registers its mirror image, so
    /// the same machinery gives Redo without a second stack to keep in step.
    func pushStep(
        restoring drawing: PKDrawing,
        elements: [PageElement]?,
        counterDrawing: PKDrawing,
        counterElements: [PageElement]?,
        named: String,
        on canvas: PageCanvasView
    ) {
        let manager = canvas.pageUndoManager
        manager.registerUndo(withTarget: canvas) { [weak self] target in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pushStep(
                    restoring: counterDrawing, elements: counterElements,
                    counterDrawing: drawing, counterElements: elements,
                    named: named, on: target
                )
                self.restore(drawing, elements: elements, on: target)
            }
        }
        manager.setActionName(named)
    }

    /// Puts the page back to a remembered state — ink, and the elements that
    /// went with it. Used by both Undo and Redo.
    func restore(
        _ drawing: PKDrawing, elements: [PageElement]?, on canvas: PageCanvasView
    ) {
        isRewriting = true
        canvas.drawing = drawing
        Task { @MainActor [weak self] in self?.isRewriting = false }
        undoBaseline = drawing
        hasUncommittedChange = false
        processedStrokeCount = drawing.strokes.count
        if let elements {
            let revert = onReverted
            Task { @MainActor in await revert(elements) }
        }
        tracker.undoStackChanged()
        scheduleSave()
    }

    /// Hand the page to the live beautifier; it debounces and only fires once
    /// the pencil rests.
    func scheduleBeautification() {
        guard toolState.beautify.isEnabled else { return }
        beautifier.inkChanged(
            pageID: pageID,
            settings: toolState.beautify,
            fontName: beautifyFontName,
            pageSize: pageSize,
            drawing: { [weak self] in self?.canvas?.drawing },
            apply: { [weak self] plan, remaining in
                guard let self, let canvas = self.canvas else { return false }
                // Never swap the ink out from under a moving pencil — nor from
                // under a held shape, where the canvas is deliberately muted
                // and `isUsingTool` has already gone false. Refusing here keeps
                // the beautifier's bookkeeping intact, and the pass re-runs
                // when the hand next rests.
                guard !self.isUsingTool, !self.isPencilDown else { return false }
                // Everything the user did up to here is its own step; the
                // beautification that follows must not swallow it.
                self.commitUndoStep()
                let inkBefore = canvas.drawing
                // Typeset text FIRST, then take the ink away. The other order
                // leaves a frame with neither on the page, which is what made
                // beautification look like the writing vanished and something
                // else appeared, instead of the writing turning into type.
                let elements = await self.onBeautified(plan)
                self.processedStrokeCount = remaining.strokes.count
                // Beautification is ONE step in either direction: the ink went
                // away and type appeared in its place, so Undo has to restore
                // both halves or the page is left with the words twice over —
                // and Redo has to put both back.
                self.registerBeautifyStep(
                    inkBefore: inkBefore, elementsBefore: elements.before,
                    inkAfter: remaining, elementsAfter: elements.after,
                    on: canvas
                )
                self.replace(remaining, on: canvas)
                self.scheduleSave()
                return true
            }
        )
    }

    /// One history step for a whole beautification pass, both ways round.
    func registerBeautifyStep(
        inkBefore: PKDrawing, elementsBefore: [PageElement],
        inkAfter: PKDrawing, elementsAfter: [PageElement],
        on canvas: PageCanvasView
    ) {
        undoBaseline = inkAfter
        hasUncommittedChange = false
        pushStep(
            restoring: inkBefore, elements: elementsBefore,
            counterDrawing: inkAfter, counterElements: elementsAfter,
            named: "Beautify", on: canvas
        )
        tracker.undoStackChanged()
    }
}
