import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A live lasso selection, and which page it belongs to. A selection only means
/// anything on the page it was drawn on, so the page id travels with it.
struct PageSelection: Equatable {
    let pageID: UUID
    var caught: LassoCatch
}

/// What Copy captured: the picture, and WHERE it came from.
///
/// The page and frame travel with the image itself rather than being read back
/// off `lassoSelection` at paste time. `lassoSelection` is ephemeral — "Done",
/// a tap elsewhere on the page, or drawing something new all clear it — but the
/// Paste chip stays on screen as long as `copiedSnip` does, so a user who
/// dismisses the marching-ants selection (or simply taps the page for any other
/// reason) before pressing Paste must still get the region back exactly where
/// it was copied from. Losing that origin the moment the selection UI closed is
/// what silently downgraded Paste to a centered insert, which — on a page taller
/// than the viewport — can land off-screen and read as "paste does nothing"
/// even though it worked, the exact failure `insertImage(frame:on:)` exists to
/// avoid.
struct CopiedSnip {
    let image: UIImage
    let pageID: UUID
    let frame: CGRect
}

/// Taps the page in a tap-to-act mode (fill, or a straight-line direction). A
/// bare tap surface rather than a gesture on the canvas, because the canvas's
/// own drawing recognizer is disabled in these modes and its scroll view would
/// otherwise swallow the touch.
struct TapPlacementLayer: View {
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
            // An open shape is no longer a failure — the paint simply goes as far
            // as it can reach, under the ink. What's left is a tap buried in ink.
            editorNotice = "That's all ink — tap in the space you want filled."
            return
        }
        let colour = toolState.currentColor(theme: theme)
        await model.insertFill(
            outline: outline, colorHex: colour.hexString, on: page.id
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Straight line

/// Which edge-to-edge direction the straight-line tool inks.
enum LineAxis {
    case horizontal, vertical
}

extension EditorScreen {
    /// Inks a perfectly straight line all the way across the page through
    /// `point`, in the SAME ink the pen tray is holding (colour, thickness,
    /// ink type) — a real `PKStroke`, not a separate element, so it erases
    /// exactly like anything else drawn by hand: a pixel eraser takes a bite
    /// out of it, a stroke eraser removes the whole line, same as any stroke.
    @MainActor
    func drawStraightLine(through point: CGPoint, axis: LineAxis, on page: PageRecord) async {
        guard let drawingBefore = tracker.drawing(for: page.id) else { return }
        let size = page.logicalSize
        let path: [CGPoint]
        switch axis {
        case .horizontal:
            path = [CGPoint(x: 0, y: point.y), CGPoint(x: size.width, y: point.y)]
        case .vertical:
            path = [CGPoint(x: point.x, y: 0), CGPoint(x: point.x, y: size.height)]
        }
        let (ink, width) = toolState.currentPenInk(theme: theme)
        let stroke = ShapeSnapper.stroke(from: path, ink: ink, width: width)
        let drawingAfter = PKDrawing(strokes: drawingBefore.strokes + [stroke])
        tracker.setDrawing(drawingAfter, for: page.id)
        tracker.registerElementStep(
            pageID: page.id, drawingBefore: drawingBefore, drawingAfter: drawingAfter,
            elementsBefore: page.elements, elementsAfter: page.elements, named: "Line"
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
        let elementsBefore = model.page(selection.pageID)?.elements ?? []
        var drawingBefore: PKDrawing?
        var drawingAfter: PKDrawing?
        if !selection.caught.strokeIndices.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            drawingBefore = drawing
            let dropped = Set(selection.caught.strokeIndices)
            let survivors = drawing.strokes.enumerated()
                .filter { !dropped.contains($0.offset) }
                .map(\.element)
            let after = PKDrawing(strokes: survivors)
            drawingAfter = after
            tracker.setDrawing(after, for: selection.pageID)
        }
        for id in selection.caught.elementIDs {
            await model.deleteElement(id, on: selection.pageID)
        }
        let elementsAfter = elementsBefore.filter { !selection.caught.elementIDs.contains($0.id) }
        tracker.registerElementStep(
            pageID: selection.pageID, drawingBefore: drawingBefore, drawingAfter: drawingAfter,
            elementsBefore: elementsBefore, elementsAfter: elementsAfter, named: "Delete Selection"
        )
        lassoSelection = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    func duplicateSelection() async {
        guard let selection = lassoSelection else { return }
        // A copy has to land somewhere you can see it, so it comes in offset.
        let offset = CGSize(width: 24, height: 24)
        let elementsBefore = model.page(selection.pageID)?.elements ?? []
        var drawingBefore: PKDrawing?
        var drawingAfter: PKDrawing?
        var newStrokeIndices: [Int] = []
        var newBoxes: [CGRect] = []
        if !selection.caught.strokeIndices.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            drawingBefore = drawing
            let copies = selection.caught.strokeIndices.compactMap { index -> PKStroke? in
                guard drawing.strokes.indices.contains(index) else { return nil }
                var stroke = drawing.strokes[index]
                stroke.transform = stroke.transform.concatenating(
                    CGAffineTransform(translationX: offset.width, y: offset.height)
                )
                return stroke
            }
            let after = PKDrawing(strokes: drawing.strokes + copies)
            drawingAfter = after
            newStrokeIndices = Array(drawing.strokes.count..<after.strokes.count)
            newBoxes = copies.map(\.renderBounds)
            tracker.setDrawing(after, for: selection.pageID)
        }
        for id in selection.caught.elementIDs {
            await model.duplicateElement(id, on: selection.pageID, offset: offset)
        }
        let elementsAfter = model.page(selection.pageID)?.elements ?? []
        let newElementIDs = elementsAfter
            .map(\.id)
            .filter { id in !elementsBefore.contains { $0.id == id } }
        for id in newElementIDs {
            if let element = elementsAfter.first(where: { $0.id == id }) {
                newBoxes.append(element.frame)
            }
        }
        tracker.registerElementStep(
            pageID: selection.pageID, drawingBefore: drawingBefore, drawingAfter: drawingAfter,
            elementsBefore: elementsBefore, elementsAfter: elementsAfter, named: "Duplicate Selection"
        )
        // Land the duplicate in a fresh selection over just the new ink/
        // elements, ready to drag — the same "just made this, now move it"
        // affordance Paste already gets, instead of leaving the user staring
        // at an identical-looking page with no sign anything new is there.
        var newCatch = LassoCatch()
        newCatch.strokeIndices = newStrokeIndices
        newCatch.elementIDs = newElementIDs
        newCatch.bounds = LassoSelection.bounds(of: newBoxes) ?? .null
        lassoSelection = PageSelection(pageID: selection.pageID, caught: newCatch)
    }

    /// Copy takes a PICTURE of what the lasso is holding — the ink, the photos,
    /// the fills, whatever is in there — and puts that on the pasteboard.
    ///
    /// It used to copy only the *text* of any text boxes caught, which meant
    /// circling a diagram and pressing Copy reported that there was nothing to
    /// copy. Circling something is a spatial act: what the user has selected is a
    /// region of the page, and the honest answer to "copy this" is that region as
    /// it looks. Text boxes are rendered along with everything else rather than
    /// extracted, so what lands in the other app is what was on the page.
    @MainActor
    func copySelection() {
        guard let selection = lassoSelection else { return }
        guard let image = snapshotSelection(selection) else {
            editorNotice = "Nothing to copy."
            return
        }
        // Both representations: apps that want a picture get the PNG (with its
        // transparency intact), and the plain image satisfies everything else.
        var item: [String: Any] = [UTType.image.identifier: image]
        if let png = image.pngData() {
            item[UTType.png.identifier] = png
        }
        UIPasteboard.general.items = [item]
        // Kept in hand as well, so the Paste chip can put it straight back onto
        // the page. A Copy you can only spend in another app is half a Copy.
        // The page and frame travel WITH the image (see `CopiedSnip`) rather
        // than being read back off `lassoSelection`, which the user is free to
        // dismiss before ever pressing Paste.
        let snip = CopiedSnip(image: image, pageID: selection.pageID, frame: selection.caught.bounds)
        withAnimation(.spring(duration: 0.3)) { copiedSnip = snip }
        editorNotice = "Copied — press Paste to place it."
    }

    /// Drops the copied region back onto the page as a picture you can move and
    /// resize, and hands the pencil to Move so it is adjustable straight away.
    ///
    /// Lands at the SAME frame the region was copied from, not the page's
    /// logical center — a page taller than the viewport put a centered paste
    /// off-screen from wherever the user was actually looking, which read as
    /// "paste does nothing" even though the insert had genuinely succeeded.
    /// That frame comes from `copiedSnip`, captured once at Copy time — NOT
    /// from `lassoSelection`, which is often already gone by the time Paste is
    /// pressed (its own "Done" button, or a tap anywhere else on the page,
    /// clears it) while the Paste chip stays on screen regardless. Reading the
    /// frame off `lassoSelection` here is exactly what silently reintroduced
    /// the centered-and-invisible paste this fix is for.
    @MainActor
    func pasteSnip() async {
        lassoSelection = nil
        let landedPageID: UUID
        let elementsBefore: [PageElement]
        if let snip = copiedSnip {
            guard let data = snip.image.pngData() else {
                editorNotice = "Nothing to paste."
                return
            }
            landedPageID = snip.pageID
            elementsBefore = model.page(snip.pageID)?.elements ?? []
            await model.insertImage(
                data, fileExtension: "png", frame: snip.frame, on: snip.pageID, renderAboveInk: true
            )
        } else if let pbImage = UIPasteboard.general.image, let data = pbImage.pngData() {
            // Something copied from outside the app: there's no source page or
            // frame to land it back at, so centering on the focused page is the
            // only sensible default.
            guard let insertedPageID = model.targetPageID else {
                editorNotice = "Nothing to paste."
                return
            }
            landedPageID = insertedPageID
            elementsBefore = model.page(insertedPageID)?.elements ?? []
            await model.insertImage(data, fileExtension: "png", renderAboveInk: true)
        } else {
            editorNotice = "Nothing to paste."
            return
        }
        let elementsAfter = model.page(landedPageID)?.elements ?? []
        tracker.registerElementStep(
            pageID: landedPageID, elementsBefore: elementsBefore, elementsAfter: elementsAfter, named: "Paste"
        )
        // The one element in `elementsAfter` that wasn't in `elementsBefore` —
        // there's exactly one, since this function only ever appends a single
        // image. Marks it pending: adjustable (drag/pinch already work off
        // `selectedElementID`'s resize handle) with its own Confirm/Discard bar
        // (`pastePendingActions`) until the user settles on where it lands,
        // instead of dropping it silently with no way to undo but the
        // page-wide undo button or a long-press Delete.
        let beforeIDs = Set(elementsBefore.map(\.id))
        let newElementID = elementsAfter.first { !beforeIDs.contains($0.id) }?.id
        selectedElementID = newElementID
        pendingPasteElementID = newElementID
        // Drag and pinch only work when the pencil isn't drawing, so the mode that
        // makes the paste adjustable is the mode it should arrive in.
        toolState.select(.hand)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        editorNotice = "Pasted — drag to move, pinch to resize."
    }

    /// Confirm on the pending-paste bar: the placement is settled, so the
    /// adjustment frame goes away. The element itself is untouched — it's an
    /// ordinary page element from here on, tap it again like any other image
    /// to bring its resize handle back and move it further.
    @MainActor
    func confirmPendingPaste() {
        pendingPasteElementID = nil
        selectedElementID = nil
    }

    /// The X on the pending-paste bar: undoes the paste outright rather than
    /// leaving it on the page for a long-press Delete to find, since the whole
    /// point of showing this bar before the user has moved on is "I didn't
    /// mean to put that there."
    @MainActor
    func discardPendingPaste(_ element: PageElement, on pageID: UUID) async {
        let before = model.page(pageID)?.elements ?? []
        tracker.registerElementStep(
            pageID: pageID, elementsBefore: before,
            elementsAfter: before.filter { $0.id != element.id }, named: "Discard paste"
        )
        await model.deleteElement(element.id, on: pageID)
        pendingPasteElementID = nil
        selectedElementID = nil
    }

    /// Renders the caught region at its page-logical size, ink first and page
    /// elements over it, in the order the page draws them.
    func snapshotSelection(_ selection: PageSelection) -> UIImage? {
        let bounds = selection.caught.bounds
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return nil }
        guard let page = model.page(selection.pageID) else { return nil }

        let scale = Self.snapshotScale(for: bounds.size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false

        let caughtElements = page.elements.filter { selection.caught.elementIDs.contains($0.id) }
        let strokes = selection.caught.strokeIndices
        let drawing = tracker.drawing(for: selection.pageID)

        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            // Same order as the page: paint under the ink, everything else over it.
            for element in caughtElements where element.kind == .fill {
                draw(element, in: context.cgContext, page: page)
            }
            if let drawing, !strokes.isEmpty {
                let caught = PKDrawing(strokes: strokes.compactMap { index in
                    drawing.strokes.indices.contains(index) ? drawing.strokes[index] : nil
                })
                // `image(from:scale:)` returns the crop already positioned at the
                // origin, so it is drawn back at the region's own place in the
                // page — the translation above then puts it where it belongs.
                caught.image(from: bounds, scale: scale).draw(in: bounds)
            }
            for element in caughtElements where element.kind != .fill {
                draw(element, in: context.cgContext, page: page)
            }
        }
    }

    /// One element into the snapshot. Only what can be drawn without a view
    /// hierarchy: pictures, fills and text. A voice note or a file is a control,
    /// not a mark on the page, so a picture of one would be a picture of an icon.
    private func draw(_ element: PageElement, in context: CGContext, page: PageRecord) {
        let frame = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
        switch element.kind {
        case .image:
            guard let filename = element.payloadFilename else { break }
            let image = backgroundCache.image(for: filename)
                ?? (try? Data(contentsOf: model.mediaURL(filename: filename))).flatMap(UIImage.init(data:))
            if let image {
                backgroundCache.set(image, for: filename)
                image.draw(in: frame)
            }
        case .fill:
            let outline = element.points.map { CGPoint(x: $0.x, y: $0.y) }
            guard outline.count > 2, let hex = element.colorHex,
                  let color = ThemeColor(hex: hex) else { break }
            context.saveGState()
            context.setFillColor(color.uiColor.cgColor)
            context.beginPath()
            context.move(to: outline[0])
            for point in outline.dropFirst() { context.addLine(to: point) }
            context.closePath()
            context.fillPath()
            context.restoreGState()
        case .text, .codeBlock:
            guard let text = element.text, !text.isEmpty else { break }
            let color = element.colorHex.flatMap(ThemeColor.init(hex:))?.uiColor ?? .label
            let font = FontResolver.uiFont(
                named: element.fontName, size: element.fontSize ?? 20
            )
            let style = NSMutableParagraphStyle()
            style.lineSpacing = element.lineSpacing ?? 0
            (text as NSString).draw(
                in: frame,
                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
            )
        case .functionPlot:
            // Unlike an image/fill/text, a plot has no stored pixels or points
            // to draw straight into a `CGContext` — its curve only exists as
            // code that runs `FunctionPlotView` (parse, sample, draw). Reusing
            // that view via `ImageRenderer` instead of reimplementing axis/
            // curve math here a second time is the same reasoning
            // `PageContentView.functionPlotView` already renders it with, so a
            // lasso copy of a plot draws the actual graph instead of leaving
            // its frame empty — silently skipping it drew nothing but the
            // lasso's OWN outline overlay, which is what a paste showed.
            let radius = element.codeCornerRadius ?? 10
            let background = element.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.surfaceRaised
            let lineColor = element.textColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accent
            let transparent = element.backgroundIsTransparent ?? false
            let plot = FunctionPlotView(
                expression: element.functionExpression ?? "",
                secondaryExpression: element.functionSecondaryExpression,
                tertiaryExpression: element.functionTertiaryExpression,
                mode: element.resolvedPlotMode,
                window: element.functionWindow ?? FunctionPlotSettings().window,
                lineColor: lineColor.color, axisColor: lineColor.color,
                axisX: element.axisXDisplay, axisY: element.axisYDisplay, axisZ: element.axisZDisplay
            )
            .padding(6)
            .background(
                transparent ? Color.clear : background.color,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                if !transparent {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(theme.separator.color, lineWidth: 0.5)
                }
            }
            .frame(width: frame.width, height: frame.height)
            let renderer = ImageRenderer(content: plot)
            renderer.scale = 3
            renderer.uiImage?.draw(in: frame)
        case .file, .audio, .link, .tape, .unknown:
            // A voice note, file or link is a control, not a mark on the page —
            // a picture of one would be a picture of an icon.
            break
        }
    }

    /// A snapshot is for pasting somewhere else, so it wants to be crisp — but a
    /// lasso around half a page at 3× is a bitmap nothing wants to receive.
    static func snapshotScale(for size: CGSize) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return 1 }
        return min(3, max(1, 2400 / longest))
    }

    @MainActor
    func moveSelection(by offset: CGSize) async {
        guard let selection = lassoSelection, offset != .zero else { return }
        let elementsBefore = model.page(selection.pageID)?.elements ?? []
        var drawingBefore: PKDrawing?
        var drawingAfter: PKDrawing?
        if !selection.caught.strokeIndices.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            drawingBefore = drawing
            let moving = Set(selection.caught.strokeIndices)
            let strokes = drawing.strokes.enumerated().map { index, stroke -> PKStroke in
                guard moving.contains(index) else { return stroke }
                var moved = stroke
                moved.transform = stroke.transform.concatenating(
                    CGAffineTransform(translationX: offset.width, y: offset.height)
                )
                return moved
            }
            let after = PKDrawing(strokes: strokes)
            drawingAfter = after
            tracker.setDrawing(after, for: selection.pageID)
        }
        for id in selection.caught.elementIDs {
            await model.moveElement(id, on: selection.pageID, by: offset)
        }
        let elementsAfter = model.page(selection.pageID)?.elements ?? []
        tracker.registerElementStep(
            pageID: selection.pageID, drawingBefore: drawingBefore, drawingAfter: drawingAfter,
            elementsBefore: elementsBefore, elementsAfter: elementsAfter, named: "Move Selection"
        )
        lassoSelection?.caught.bounds = selection.caught.bounds
            .offsetBy(dx: offset.width, dy: offset.height)
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

        let elementsBefore = model.page(selection.pageID)?.elements ?? []
        var drawingBefore: PKDrawing?
        var drawingAfter: PKDrawing?
        if !selection.caught.strokeIndices.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            drawingBefore = drawing
            let resizing = Set(selection.caught.strokeIndices)
            let strokes = drawing.strokes.enumerated().map { index, stroke -> PKStroke in
                guard resizing.contains(index) else { return stroke }
                var scaled = stroke
                scaled.transform = stroke.transform.concatenating(transform)
                return scaled
            }
            let after = PKDrawing(strokes: strokes)
            drawingAfter = after
            tracker.setDrawing(after, for: selection.pageID)
        }
        for id in selection.caught.elementIDs {
            await model.transformElement(id, on: selection.pageID, by: transform)
        }
        let elementsAfter = model.page(selection.pageID)?.elements ?? []
        tracker.registerElementStep(
            pageID: selection.pageID, drawingBefore: drawingBefore, drawingAfter: drawingAfter,
            elementsBefore: elementsBefore, elementsAfter: elementsAfter, named: "Resize Selection"
        )
        lassoSelection?.caught.bounds = newBounds
    }
}
