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
        editorNotice = "Copied."
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
            if let drawing, !strokes.isEmpty {
                let caught = PKDrawing(strokes: strokes.compactMap { index in
                    drawing.strokes.indices.contains(index) ? drawing.strokes[index] : nil
                })
                // `image(from:scale:)` returns the crop already positioned at the
                // origin, so it is drawn back at the region's own place in the
                // page — the translation above then puts it where it belongs.
                caught.image(from: bounds, scale: scale).draw(in: bounds)
            }
            for element in caughtElements {
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
        case .text:
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
        case .file, .audio, .link, .tape:
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
