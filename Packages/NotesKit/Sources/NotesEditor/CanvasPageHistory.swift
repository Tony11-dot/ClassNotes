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
        // Undo/redo puts the page back to a state the user explicitly asked
        // for — the vanish guard, which exists only for UNEXPLAINED loss,
        // must not fight that by re-inserting a shape the target state
        // doesn't have.
        guardedShapeStroke = nil
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
        // Captured on the FIRST `drawing()` call the beautifier makes (its
        // starting snapshot), left alone on the second — see `rewriteGeneration`.
        var startGeneration: Int?
        beautifier.inkChanged(
            pageID: pageID,
            settings: toolState.beautify,
            fontName: beautifyFontName,
            pageSize: pageSize,
            drawing: { [weak self] in
                guard let self else { return nil }
                if startGeneration == nil { startGeneration = self.rewriteGeneration }
                return self.canvas?.drawing
            },
            apply: { [weak self] plan, remaining in
                guard let self, let canvas = self.canvas else { return false }
                // Never swap the ink out from under a moving pencil — nor from
                // under a held shape, where the canvas is deliberately muted
                // and `isUsingTool` has already gone false. Refusing here keeps
                // the beautifier's bookkeeping intact, and the pass re-runs
                // when the hand next rests.
                guard !self.isUsingTool, !self.isPencilDown else { return false }
                // Something rewrote a stroke IN PLACE (pen shaping, a shape
                // snap, ruling, scribble-erase) since this pass took its
                // starting snapshot — `plan.consumedStrokes` are indices into
                // that snapshot, and if the content at one of those indices
                // changed underneath it, filtering `remaining` by index would
                // delete whatever is there now, not what Vision actually read.
                // Refuse and let the existing retry pick it up once things
                // have settled, exactly like the pencil-down guard above.
                guard startGeneration == self.rewriteGeneration else { return false }
                // Everything the user did up to here is its own step; the
                // beautification that follows must not swallow it.
                self.commitUndoStep()
                let inkBefore = canvas.drawing
                // Typeset text FIRST, then take the ink away. The other order
                // leaves a frame with neither on the page, which is what made
                // beautification look like the writing vanished and something
                // else appeared, instead of the writing turning into type.
                //
                // `onBeautified` is a genuine suspension point (it resolves
                // fonts and writes the manifest) — every guard above was
                // checked BEFORE it, and nothing re-checks them after. A hand
                // that starts a new stroke, or a shape that settles and
                // commits, while this is in flight is invisible to those
                // stale checks: `remaining` was built from a snapshot taken
                // before the wait, and applying it unconditionally below wipes
                // whatever landed on the canvas during it, silently — this was
                // the actual mechanism behind ink and settled shapes alike
                // vanishing sometime after a beautify pass had already looked
                // safe to apply. `onBeautified` has already written the new
                // elements to the manifest by the time it returns, so backing
                // out here has to undo that too, or the typeset words and the
                // original ink both end up on the page at once.
                let elements = await self.onBeautified(plan)
                guard !self.isUsingTool, !self.isPencilDown,
                      startGeneration == self.rewriteGeneration else {
                    await self.onReverted(elements.before)
                    return false
                }
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
