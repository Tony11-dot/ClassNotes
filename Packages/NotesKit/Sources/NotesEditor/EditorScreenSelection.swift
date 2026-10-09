import ClassMateTheme
import NotesModels
import PencilKit
import SwiftUI
import UIKit

/// What the lasso does to the INK it caught. Pure over `PKDrawing`, so each
/// edit is testable without a canvas.
enum LassoInk {
    /// `drawing` with the strokes at `indices` placed through `transform`, and
    /// their keys afterwards. A stroke's placement is part of its key, so the
    /// selection has to re-key after every move, resize or turn.
    static func transformed(
        _ drawing: PKDrawing, at indices: Set<Int>, by transform: CGAffineTransform
    ) -> (drawing: PKDrawing, keys: [StrokeKey]) {
        var keys: [StrokeKey] = []
        let strokes = drawing.strokes.enumerated().map { index, stroke -> PKStroke in
            guard indices.contains(index) else { return stroke }
            var placed = stroke
            placed.transform = stroke.transform.concatenating(transform)
            keys.append(StrokeKey(placed))
            return placed
        }
        return (PKDrawing(strokes: strokes), keys)
    }

    /// `drawing` with the strokes at `indices` in `color`. Each keeps its own
    /// ink type and its own transparency, so recoloured highlighter is still
    /// highlighter. Colour isn't part of a stroke's key, so the selection holds.
    static func recoloured(_ drawing: PKDrawing, at indices: Set<Int>, to color: UIColor) -> PKDrawing {
        let strokes = drawing.strokes.enumerated().map { index, stroke -> PKStroke in
            guard indices.contains(index) else { return stroke }
            var painted = stroke
            painted.ink = PKInk(stroke.ink.inkType, color: color.withAlphaComponent(stroke.ink.color.cgColor.alpha))
            return painted
        }
        return PKDrawing(strokes: strokes)
    }

    /// The box everything caught covers, drawn as it now is: each stroke's
    /// rendered bounds and each element as turned.
    static func bounds(of strokes: [PKStroke], elements: [PageElement]) -> CGRect {
        var box = CGRect.null
        for stroke in strokes { box = box.union(stroke.renderBounds) }
        for element in elements { box = box.union(element.coveredBounds) }
        return box
    }
}

/// Whole-selection edits: move, resize, turn and recolour. Each changes the ink
/// and the elements together and is ONE step in the page's history.
extension EditorScreen {

    @MainActor
    func moveSelection(by offset: CGSize) async {
        guard let selection = lassoSelection, offset != .zero else { return }
        let shift = CGAffineTransform(translationX: offset.width, y: offset.height)
        await editSelection(selection, named: "Move Selection", ink: { drawing, indices in
            LassoInk.transformed(drawing, at: indices, by: shift)
        }, elements: {
            await model.moveElements(selection.caught.elementIDs, on: selection.pageID, by: offset)
        })
        lassoSelection?.caught.bounds = selection.caught.bounds.offsetBy(dx: offset.width, dy: offset.height)
    }

    /// Scales the whole catch — ink AND elements — to fit a new box, the same
    /// way `moveSelection` translates the whole catch rather than just
    /// redrawing the marching-ants outline around it. Top-left anchored, same
    /// as the corner handle that drove it.
    @MainActor
    func resizeSelection(to newBounds: CGRect) async {
        guard let selection = lassoSelection else { return }
        let old = selection.caught.bounds
        guard old.width > 0, old.height > 0, newBounds.width > 0, newBounds.height > 0 else { return }
        let transform = CGAffineTransform(translationX: -old.minX, y: -old.minY)
            .concatenating(CGAffineTransform(scaleX: newBounds.width / old.width, y: newBounds.height / old.height))
            .concatenating(CGAffineTransform(translationX: newBounds.minX, y: newBounds.minY))
        await editSelection(selection, named: "Resize Selection", ink: { drawing, indices in
            LassoInk.transformed(drawing, at: indices, by: transform)
        }, elements: {
            await model.transformElements(selection.caught.elementIDs, on: selection.pageID, by: transform)
        })
        lassoSelection?.caught.bounds = newBounds
    }

    /// Turns the whole catch about its centre. Ink and fills turn exactly;
    /// a text box or photo turns about its own centre and travels with the
    /// rest (`PageElement.rotated`). The outline becomes the box around what
    /// it now covers.
    @MainActor
    func rotateSelection(by radians: CGFloat) async {
        guard let selection = lassoSelection, radians != 0 else { return }
        let box = selection.caught.bounds
        let pivot = CGPoint(x: box.midX, y: box.midY)
        let turn = SelectionRotation.transform(radians, about: pivot)
        await editSelection(selection, named: "Rotate Selection", ink: { drawing, indices in
            LassoInk.transformed(drawing, at: indices, by: turn)
        }, elements: {
            await model.rotateElements(selection.caught.elementIDs, on: selection.pageID, by: radians, about: pivot)
        })
        refreshSelectionBounds()
    }

    /// Paints everything caught in `hex`: ink, text, fills, tape, a plot's
    /// curve. Photos and files keep their own colours.
    @MainActor
    func recolorSelection(_ hex: String) async {
        guard let selection = lassoSelection, let color = ThemeColor(hex: hex)?.uiColor else { return }
        await editSelection(selection, named: "Recolor Selection", ink: { drawing, indices in
            (LassoInk.recoloured(drawing, at: indices, to: color), [])
        }, elements: {
            await model.recolorElements(selection.caught.elementIDs, on: selection.pageID, hex: hex)
        }, rekeys: false)
    }

    /// The shared shape of every whole-selection edit: change the caught ink,
    /// change the caught elements (one manifest write), register ONE undo
    /// step carrying both, and keep the selection on what it is holding.
    @MainActor
    private func editSelection(
        _ selection: PageSelection,
        named name: String,
        ink: (PKDrawing, Set<Int>) -> (drawing: PKDrawing, keys: [StrokeKey]),
        elements: () async -> Void,
        rekeys: Bool = true
    ) async {
        let elementsBefore = model.page(selection.pageID)?.elements ?? []
        var drawingBefore: PKDrawing?
        var drawingAfter: PKDrawing?
        var keys: [StrokeKey] = []
        if !selection.caught.strokes.isEmpty, let drawing = tracker.drawing(for: selection.pageID) {
            drawingBefore = drawing
            let edited = ink(drawing, Set(selection.caught.strokeIndices(in: drawing)))
            drawingAfter = edited.drawing
            keys = edited.keys
            tracker.setDrawing(edited.drawing, for: selection.pageID)
        }
        await elements()
        tracker.registerElementStep(
            pageID: selection.pageID, drawingBefore: drawingBefore, drawingAfter: drawingAfter,
            elementsBefore: elementsBefore, elementsAfter: model.page(selection.pageID)?.elements ?? [],
            named: name
        )
        if rekeys, !selection.caught.strokes.isEmpty { lassoSelection?.caught.strokes = keys }
        lassoSelection?.caught.edits += 1
    }

    /// Re-measures the selection's outline from what it now covers.
    @MainActor
    private func refreshSelectionBounds() {
        guard let selection = lassoSelection else { return }
        let drawing = tracker.drawing(for: selection.pageID)
        let strokes = drawing.map { drawing in
            selection.caught.strokeIndices(in: drawing).map { drawing.strokes[$0] }
        } ?? []
        let elements = (model.page(selection.pageID)?.elements ?? [])
            .filter { selection.caught.elementIDs.contains($0.id) }
        let box = LassoInk.bounds(of: strokes, elements: elements)
        if !box.isNull { lassoSelection?.caught.bounds = box }
    }
}
