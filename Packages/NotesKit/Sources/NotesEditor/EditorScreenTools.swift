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
    /// The SAME bytes that went on the pasteboard. Copy has to encode a PNG
    /// anyway, and Paste needs a PNG to store beside the page — so keeping the
    /// first one spares the second encode entirely. That is not a micro
    /// optimisation: a half-page selection is a couple of megapixels, and
    /// encoding it is tens of milliseconds of a blocked main actor, which is
    /// felt as the Paste button hanging before anything appears.
    let png: Data
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
        guard let region = FillTool.region(
            in: drawing, at: point, pageSize: page.logicalSize
        ) else {
            // An open shape is no longer a failure — the paint simply goes as far
            // as it can reach, under the ink. What's left is a tap buried in ink.
            editorNotice = "That's all ink — tap in the space you want filled."
            return
        }
        let colour = toolState.currentColor(theme: theme)
        await model.insertFill(
            outline: region.outline, holes: region.holes, colorHex: colour.hexString, on: page.id
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
        // Anything whose box misses the loop's box cannot have a single point
        // inside the loop, so it is dropped before the per-point test — which is
        // the expensive one, and which a page of handwriting would otherwise pay
        // for thousands of times over for ink nowhere near the circle drawn.
        // Exact, not approximate: the result is identical either way.
        let reach = LassoSelection.boundingBox(of: loop) ?? .null

        if let drawing = tracker.drawing(for: page.id) {
            for stroke in drawing.strokes {
                guard stroke.renderBounds.intersects(reach) else { continue }
                let samples = stroke.path
                    .interpolatedPoints(by: .distance(6))
                    .map { $0.location.applying(stroke.transform) }
                guard !samples.isEmpty, LassoSelection.catches(loop, samples) else { continue }
                caught.strokes.append(StrokeKey(stroke))
                boxes.append(stroke.renderBounds)
            }
        }
        for element in page.elements {
            let frame = CGRect(
                x: element.x, y: element.y, width: element.width, height: element.height
            )
            guard frame.intersects(reach) else { continue }
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
        if !selection.caught.strokes.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            drawingBefore = drawing
            let dropped = Set(selection.caught.strokeIndices(in: drawing))
            let survivors = drawing.strokes.enumerated()
                .filter { !dropped.contains($0.offset) }
                .map(\.element)
            let after = PKDrawing(strokes: survivors)
            drawingAfter = after
            tracker.setDrawing(after, for: selection.pageID)
        }
        await model.deleteElements(selection.caught.elementIDs, on: selection.pageID)
        let elementsAfter = elementsBefore.filter { !selection.caught.elementIDs.contains($0.id) }
        tracker.registerElementStep(
            pageID: selection.pageID, drawingBefore: drawingBefore, drawingAfter: drawingAfter,
            elementsBefore: elementsBefore, elementsAfter: elementsAfter, named: "Delete Selection"
        )
        lassoSelection = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// How far a copy lands from what it was copied from. Shared by Duplicate
    /// and Paste so the two behave the same way: far enough to read as a second
    /// object, near enough to stay inside the region the user was looking at.
    static let pasteOffset: CGFloat = 24

    @MainActor
    func duplicateSelection() async {
        guard let selection = lassoSelection else { return }
        // A copy has to land somewhere you can see it, so it comes in offset.
        let offset = CGSize(width: Self.pasteOffset, height: Self.pasteOffset)
        let elementsBefore = model.page(selection.pageID)?.elements ?? []
        var drawingBefore: PKDrawing?
        var drawingAfter: PKDrawing?
        var newStrokes: [StrokeKey] = []
        var newBoxes: [CGRect] = []
        if !selection.caught.strokes.isEmpty,
           let drawing = tracker.drawing(for: selection.pageID) {
            drawingBefore = drawing
            let copies = selection.caught.strokeIndices(in: drawing).map { index -> PKStroke in
                var stroke = drawing.strokes[index]
                stroke.transform = stroke.transform.concatenating(
                    CGAffineTransform(translationX: offset.width, y: offset.height)
                )
                return stroke
            }
            let after = PKDrawing(strokes: drawing.strokes + copies)
            drawingAfter = after
            newStrokes = copies.map(StrokeKey.init)
            newBoxes = copies.map(\.renderBounds)
            tracker.setDrawing(after, for: selection.pageID)
        }
        let newElementIDs = await model.duplicateElements(
            selection.caught.elementIDs, on: selection.pageID, offset: offset
        )
        let elementsAfter = model.page(selection.pageID)?.elements ?? []
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
        newCatch.strokes = newStrokes
        newCatch.elementIDs = newElementIDs
        newCatch.bounds = LassoSelection.bounds(of: newBoxes) ?? .null
        // If nothing could actually be copied, put the selection down rather
        // than hand the marching ants a null box to draw itself around.
        guard !newCatch.isEmpty, !newCatch.bounds.isNull else {
            lassoSelection = nil
            return
        }
        lassoSelection = PageSelection(pageID: selection.pageID, caught: newCatch)
        // Delete, Copy and Paste all tap the hand; Duplicate was silent, which
        // made the one action whose result looks almost identical to the page
        // before it the one action that gave no sign it had run.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
    func copySelection() async {
        guard let selection = lassoSelection else { return }
        guard let image = snapshotSelection(selection) else {
            editorNotice = "Nothing to copy."
            return
        }
        // Encoding happens OFF the main actor. The snapshot itself has to be
        // rendered here — it reads the live page — but turning a couple of
        // megapixels into PNG is tens of milliseconds of pure CPU, and doing
        // that inline is a visible freeze on the one button whose whole job is
        // to feel instant.
        let png = await Task.detached(priority: .userInitiated) { image.pngData() }.value
        guard let png else {
            editorNotice = "Nothing to copy."
            return
        }
        // Both representations: apps that want a picture get the PNG (with its
        // transparency intact), and the plain image satisfies everything else.
        UIPasteboard.general.items = [[
            UTType.image.identifier: image,
            UTType.png.identifier: png,
        ]]
        // Kept in hand as well, so the Paste chip can put it straight back onto
        // the page. A Copy you can only spend in another app is half a Copy.
        // The page and frame travel WITH the image (see `CopiedSnip`) rather
        // than being read back off `lassoSelection`, which the user is free to
        // dismiss before ever pressing Paste.
        let snip = CopiedSnip(
            image: image, png: png, pageID: selection.pageID, frame: selection.caught.bounds
        )
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
            landedPageID = snip.pageID
            elementsBefore = model.page(snip.pageID)?.elements ?? []
            // Offset, for the same reason Duplicate is: landing a copy exactly
            // on top of what it was copied from puts a pixel-identical picture
            // over the original, which looks precisely like nothing happened.
            // Still anchored to where the region came from — which is the point
            // of carrying `frame` at all, since a centered paste on a page
            // taller than the viewport can land off-screen — just nudged far
            // enough to be visibly a second thing.
            let landing = Self.landingFrame(
                for: snip.frame, offsetBy: Self.pasteOffset,
                onPageOfSize: model.page(snip.pageID)?.logicalSize ?? .zero
            )
            await model.insertImage(
                snip.png, fileExtension: "png", frame: landing, on: snip.pageID,
                renderAboveInk: true
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

    /// Where a pasted copy lands: nudged off the original so it reads as a
    /// second object, then kept on the page.
    ///
    /// The nudge alone is not enough. A region copied from the bottom-right
    /// corner would be pushed partly over the edge, and a page element that
    /// starts off-page is one the user has to find before they can drag it
    /// back. Shifting it back inside is always possible here because the source
    /// frame was on the page to begin with — the copy is the same size.
    static func landingFrame(
        for source: CGRect, offsetBy offset: CGFloat, onPageOfSize page: CGSize
    ) -> CGRect {
        let nudged = source.offsetBy(dx: offset, dy: offset)
        guard page.width > 0, page.height > 0 else { return nudged }
        // A region wider or taller than the page can't be fitted; leave it be
        // rather than dragging it somewhere arbitrary.
        let x = nudged.width <= page.width
            ? min(nudged.minX, page.width - nudged.width) : nudged.minX
        let y = nudged.height <= page.height
            ? min(nudged.minY, page.height - nudged.height) : nudged.minY
        return CGRect(x: max(0, x), y: max(0, y), width: nudged.width, height: nudged.height)
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
        let drawing = tracker.drawing(for: selection.pageID)
        let strokes = drawing.map { selection.caught.strokeIndices(in: $0) } ?? []

        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            // Same order as the page: paint under the ink, everything else over it.
            for element in caughtElements where element.kind == .fill {
                draw(element, in: context.cgContext, page: page)
            }
            if let drawing, !strokes.isEmpty {
                let caught = PKDrawing(strokes: strokes.map { drawing.strokes[$0] })
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
        // A turned box is drawn turned, about its own centre, as the page draws
        // it. A fill's outline is already where it lies.
        let turned = element.rotation != 0 && element.kind != .fill
        if turned {
            context.saveGState()
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: element.rotation * .pi / 180)
            context.translateBy(x: -frame.midX, y: -frame.midY)
        }
        defer { if turned { context.restoreGState() } }
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
            let outline = element.points.map(\.cgPoint)
            guard outline.count > 2, let hex = element.colorHex,
                  let color = ThemeColor(hex: hex) else { break }
            context.saveGState()
            context.setFillColor(color.uiColor.cgColor)
            context.beginPath()
            // The outline and its holes, even-odd — as the page draws it.
            for ring in [outline] + element.holes.map({ $0.map(\.cgPoint) }) where ring.count > 2 {
                context.move(to: ring[0])
                for point in ring.dropFirst() { context.addLine(to: point) }
                context.closePath()
            }
            context.fillPath(using: .evenOdd)
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
}
