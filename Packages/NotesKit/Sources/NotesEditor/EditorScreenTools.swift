import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import SwiftUI
import UIKit

/// A live lasso selection, and which page it belongs to. A selection only means
/// anything on the page it was drawn on, so the page id travels with it.
struct PageSelection: Equatable {
    let pageID: UUID
    var caught: LassoCatch
}

/// Taps the page in fill mode. A bare tap surface rather than a gesture on the
/// canvas, because the canvas's own drawing recognizer is disabled in this mode
/// and its scroll view would otherwise swallow the touch.
struct FillPlacementLayer: View {
    let displaySize: CGSize
    let logicalSize: CGSize
    let onTap: (CGPoint) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard logicalSize.width > 0, displaySize.width > 0 else { return }
                let scale = displaySize.width / logicalSize.width
                onTap(CGPoint(x: location.x / scale, y: location.y / scale))
            }
            .frame(width: displaySize.width, height: displaySize.height)
    }
}

// MARK: - Fill

extension EditorScreen {
    /// Floods the region under `point` with the current ink colour.
    @MainActor
    func floodFill(at point: CGPoint, on page: PageRecord) async {
        guard let drawing = tracker.drawing(for: page.id), !drawing.strokes.isEmpty else {
            editorNotice = "Draw a shape first, then tap inside it to fill it."
            return
        }
        guard let outline = FillTool.outline(
            in: drawing, at: point, pageSize: page.logicalSize
        ) else {
            // The two ways a fill fails are worth telling apart: a tap on the ink
            // itself, and a shape with a gap in it that let the colour escape.
            editorNotice = "Nothing closed to fill there — check the shape for a gap."
            return
        }
        let colour = toolState.currentColor(theme: theme)
        await model.insertFill(
            outline: outline, colorHex: colour.hexString, on: page.id
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Lasso

extension EditorScreen {
    /// What a finished loop caught on `page`: the ink inside it and the elements
    /// inside it, plus the box to draw the marching ants around.
    @MainActor
    func resolveLasso(_ loop: [CGPoint], on page: PageRecord) -> LassoCatch {
        var caught = LassoCatch()
        var boxes: [CGRect] = []

        if let drawing = tracker.drawing(for: page.id) {
            for (index, stroke) in drawing.strokes.enumerated() {
                let samples = stroke.path
                    .interpolatedPoints(by: .distance(6))
                    .map { $0.location.applying(stroke.transform) }
                guard !samples.isEmpty, LassoSelection.catches(loop, samples) else { continue }
                caught.strokeIndices.append(index)
                boxes.append(stroke.renderBounds)
            }
        }
        for element in page.elements {
            let frame = CGRect(
                x: element.x, y: element.y, width: element.width, height: element.height
            )
            guard LassoSelection.catches(loop, frame: frame) else { continue }
            caught.elementIDs.append(element.id)
            boxes.append(frame)
        }
        caught.bounds = LassoSelection.bounds(of: boxes) ?? .null
        return caught
    }

    @MainActor
    func deleteSelection() async {
        guard let selection = lassoSelection else { return }
        if !selection.caught.strokeIndices.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            let dropped = Set(selection.caught.strokeIndices)
            let survivors = drawing.strokes.enumerated()
                .filter { !dropped.contains($0.offset) }
                .map(\.element)
            tracker.setDrawing(PKDrawing(strokes: survivors), for: selection.pageID)
        }
        for id in selection.caught.elementIDs {
            await model.deleteElement(id, on: selection.pageID)
        }
        lassoSelection = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    func duplicateSelection() async {
        guard let selection = lassoSelection else { return }
        // A copy has to land somewhere you can see it, so it comes in offset.
        let offset = CGSize(width: 24, height: 24)
        if !selection.caught.strokeIndices.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            let copies = selection.caught.strokeIndices.compactMap { index -> PKStroke? in
                guard drawing.strokes.indices.contains(index) else { return nil }
                var stroke = drawing.strokes[index]
                stroke.transform = stroke.transform.concatenating(
                    CGAffineTransform(translationX: offset.width, y: offset.height)
                )
                return stroke
            }
            tracker.setDrawing(PKDrawing(strokes: drawing.strokes + copies), for: selection.pageID)
        }
        for id in selection.caught.elementIDs {
            await model.duplicateElement(id, on: selection.pageID, offset: offset)
        }
        lassoSelection = nil
    }

    /// Puts the selection's words on the pasteboard. Ink can't be text, so what
    /// travels is whatever the selection contained that already WAS text —
    /// anything else would be a picture pretending to be a copy.
    @MainActor
    func copySelection() {
        guard let selection = lassoSelection else { return }
        let text = model.page(selection.pageID)?.elements
            .filter { selection.caught.elementIDs.contains($0.id) && $0.kind == .text }
            .compactMap(\.text)
            .joined(separator: "\n") ?? ""
        if text.isEmpty {
            editorNotice = "Nothing to copy as text — try Duplicate."
        } else {
            UIPasteboard.general.string = text
            editorNotice = "Copied."
        }
    }

    @MainActor
    func moveSelection(by offset: CGSize) async {
        guard let selection = lassoSelection, offset != .zero else { return }
        if !selection.caught.strokeIndices.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            let moving = Set(selection.caught.strokeIndices)
            let strokes = drawing.strokes.enumerated().map { index, stroke -> PKStroke in
                guard moving.contains(index) else { return stroke }
                var moved = stroke
                moved.transform = stroke.transform.concatenating(
                    CGAffineTransform(translationX: offset.width, y: offset.height)
                )
                return moved
            }
            tracker.setDrawing(PKDrawing(strokes: strokes), for: selection.pageID)
        }
        for id in selection.caught.elementIDs {
            await model.moveElement(id, on: selection.pageID, by: offset)
        }
        lassoSelection?.caught.bounds = selection.caught.bounds
            .offsetBy(dx: offset.width, dy: offset.height)
    }
}
