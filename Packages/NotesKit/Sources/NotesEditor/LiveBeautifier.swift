import CoreGraphics
import Foundation
import NotesDesignSystem
import NotesModels
import NotesServices
import Observation
import PencilKit
import UIKit

/// One line of handwriting that has been read back as text.
struct RecognizedLine: Equatable {
    let text: String
    /// The ink's bounding box in the page's logical space.
    let bounds: CGRect
    /// Indices into the drawing's stroke array — the ink this line replaces.
    let strokeIndices: [Int]
    /// Mean pen force across the line, 0…1 — drives "Dynamic Bold".
    let meanForce: Double
}

/// A run of already-typeset text on a page: what beautification produced, so more
/// writing on the same line appends to it instead of stacking a second box.
struct BeautifiedRun: Equatable {
    let elementID: UUID
    var frame: CGRect
    var text: String
    /// The INK this run was read from. Whether the student carried on writing on
    /// this line is a question about where their hand went, not about where the
    /// (much narrower) type ended up.
    var inkBounds: CGRect = .null
}

/// What one beautification pass should change.
struct BeautifyPlan: Equatable {
    /// Brand-new typeset runs.
    var inserts: [PageElement] = []
    /// Existing runs the new writing joined, already carrying their new text.
    var updates: [PageElement] = []
    /// Runs after the pass, for the next round's merge decisions.
    var runs: [BeautifiedRun] = []
    /// Stroke indices that were consumed and must be wiped from the canvas.
    var consumedStrokes: Set<Int> = []

    var isEmpty: Bool { inserts.isEmpty && updates.isEmpty }
}

/// A page's elements either side of a beautification pass. Undo needs the first,
/// Redo the second — a pass both inserts new runs and rewrites existing ones, so
/// "remove what was added" describes neither direction.
struct BeautifyElements: Equatable {
    var before: [PageElement] = []
    var after: [PageElement] = []
}

/// Real-time handwriting beautification.
///
/// While the setting is on, every stroke resets a short settle timer. When the
/// pencil rests, each *line* of fresh ink is recognized on-device (Vision), the
/// ink is wiped, and the same words appear in its place typeset in the chosen
/// font — matching the handwriting's own position and baseline, or a unified size
/// when "Unify Font Size & Line Spacing" is on.
///
/// Recognition, layout and merging are separated so the placement rules can be
/// tested without a canvas: `plan(...)` is pure.
@MainActor
@Observable
final class LiveBeautifier {
    /// Reads a rendered crop of ink back as text lines, each with the normalized
    /// box (Vision's convention: origin bottom-left) it was found in. Injected so
    /// the whole pass — grouping, planning, wiping, merging — can be driven in
    /// tests without Vision, which is why the plumbing went unverified while it
    /// was hardwired.
    typealias LineRecognizer = @Sendable (UIImage, String) async -> [OCRService.Line]

    /// True while a pass is recognizing, so the editor can show a hairline hint.
    private(set) var isWorking = false
    /// Set when a pass ran but read nothing back, so the editor can say so instead
    /// of leaving the user staring at unchanged ink wondering if it's even on.
    private(set) var lastPassFoundNothing = false

    /// Typeset runs per page, used to append to a line already beautified.
    private var runs: [UUID: [BeautifiedRun]] = [:]
    private var settleTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private let recognizeLine: LineRecognizer

    /// Line geometry that reads as handwriting rather than a diagram or a doodle.
    static let minimumLineHeight: CGFloat = 7
    static let maximumLineHeight: CGFloat = 130

    init(recognizer: @escaping LineRecognizer = LiveBeautifier.visionRecognizer) {
        self.recognizeLine = recognizer
    }

    /// The shipping recognizer: on-device Vision, one tight crop per line.
    ///
    /// Low-confidence readings are dropped rather than typeset. Vision always
    /// returns its best guess, and its best guess at a squiggle is a word — so
    /// without a floor here, "detection is weak" doesn't look like a miss, it looks
    /// like beautification confidently replacing writing with the wrong words.
    static let visionRecognizer: LineRecognizer = { image, language in
        guard let lines = try? await OCRService().recognize(in: image, languages: [language])
        else { return [] }
        return lines.filter { $0.confidence >= LiveBeautifier.minimumConfidence }
    }

    /// Below this, Vision is guessing. Handwriting rarely clears 0.9 even when it
    /// is read perfectly, so the bar is low — it exists to reject noise, not to
    /// demand printing.
    nonisolated static let minimumConfidence: Double = 0.2

    /// How the chosen face actually measures, so the box matches the type.
    static func metrics(fontName: String) -> TextMetrics {
        TextMetrics(
            width: { text, size in
                Double(FontResolver.measureWidth(text, name: fontName, size: size))
            },
            lineHeight: { size in
                Double(FontResolver.lineHeight(name: fontName, size: size))
            }
        )
    }

    /// Raises the "couldn't read that" hint, and takes it back down by itself.
    /// A sticky hint is worse than none: it outlives the writing it was about and
    /// reads as a permanent verdict on the feature.
    private func noteFoundNothing(_ askedRecognizer: Bool) {
        guard askedRecognizer else { return }
        lastPassFoundNothing = true
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.lastPassFoundNothing = false
        }
    }

    private func clearFoundNothing() {
        hintTask?.cancel()
        hintTask = nil
        lastPassFoundNothing = false
    }

    /// Forget a page's runs — after the ink is cleared, or the page is closed.
    func reset(pageID: UUID? = nil) {
        settleTask?.cancel()
        settleTask = nil
        if let pageID {
            runs[pageID] = nil
        } else {
            runs.removeAll()
        }
    }

    /// Called on every drawing change while beautification is on. Restarts the
    /// settle timer; the pass runs once the pencil actually rests.
    func inkChanged(
        pageID: UUID,
        settings: BeautifySettings,
        fontName: String,
        pageSize: CGSize,
        drawing: @escaping @MainActor () -> PKDrawing?,
        apply: @escaping @MainActor (BeautifyPlan, PKDrawing) async -> Bool
    ) {
        guard settings.isEnabled else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(settings.settleDelay))
            guard !Task.isCancelled, let self else { return }
            await self.run(
                pageID: pageID, settings: settings, fontName: fontName,
                pageSize: pageSize, drawing: drawing, apply: apply
            )
        }
    }

    /// Beautifies whatever ink is on the page right now, ignoring the settle timer.
    /// Used by the "beautify this page" button.
    func runNow(
        pageID: UUID,
        settings: BeautifySettings,
        fontName: String,
        pageSize: CGSize,
        drawing: @escaping @MainActor () -> PKDrawing?,
        apply: @escaping @MainActor (BeautifyPlan, PKDrawing) async -> Bool
    ) async {
        settleTask?.cancel()
        await run(
            pageID: pageID, settings: settings, fontName: fontName,
            pageSize: pageSize, drawing: drawing, apply: apply
        )
    }

    private func run(
        pageID: UUID,
        settings: BeautifySettings,
        fontName: String,
        pageSize: CGSize,
        drawing: @escaping @MainActor () -> PKDrawing?,
        apply: @escaping @MainActor (BeautifyPlan, PKDrawing) async -> Bool,
        retriesLeft: Int = 2
    ) async {
        guard let current = drawing(), !current.strokes.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }

        let pass = await recognize(current, settings: settings, pageSize: pageSize)
        let lines = pass.lines
        guard !lines.isEmpty else {
            // Only "couldn't read that" when we actually ASKED and got nothing.
            // Ink that never looked like writing in the first place (a diagram, a
            // doodle, a single tick) isn't a failure, and reporting it as one made
            // the hint permanent — it was on screen whatever the user did.
            noteFoundNothing(pass.askedRecognizer)
            return
        }
        clearFoundNothing()

        let plan = Self.plan(
            lines: lines,
            existing: runs[pageID] ?? [],
            settings: settings,
            fontName: fontName,
            colorHex: nil,
            pageSize: pageSize,
            metrics: Self.metrics(fontName: fontName)
        )
        guard !plan.isEmpty else {
            noteFoundNothing(true)
            return
        }

        // The canvas may have changed while Vision was working — only wipe the
        // strokes we actually read, and leave anything drawn since untouched.
        guard let latest = drawing() else { return }
        let remaining = latest.strokes.enumerated()
            .filter { !plan.consumedStrokes.contains($0.offset) }
            .map(\.element)
        // Only remember the new runs if the canvas actually took the pass. A
        // refused apply (the pencil came back down mid-pass) must leave the page's
        // run list alone, or the next pass would append to text that isn't there.
        if await apply(plan, PKDrawing(strokes: remaining)) {
            runs[pageID] = plan.runs
            return
        }

        // Refused. The work is finished and correct — it just arrived while the
        // pencil was down. Ask again shortly rather than dropping it: a refusal
        // used to end the pass for good, so writing a line and then resting the
        // tip on the page meant the line was never beautified at all.
        guard retriesLeft > 0 else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled, let self else { return }
            await self.run(
                pageID: pageID, settings: settings, fontName: fontName,
                pageSize: pageSize, drawing: drawing, apply: apply,
                retriesLeft: retriesLeft - 1
            )
        }
    }

    // MARK: - Recognition

    /// Groups the drawing's strokes into lines and reads each one. Each line is
    /// rendered on its own, tightly cropped and upscaled — Vision is far more
    /// accurate on a dense crop of one line than on a mostly-empty page.
    /// One recognition sweep: what was read, and whether the recognizer was asked
    /// at all — the two are different failures and only one is worth telling the
    /// user about.
    struct RecognitionPass {
        var lines: [RecognizedLine] = []
        var askedRecognizer = false
    }

    /// Reads the page's fresh ink in ONE pass and works out which strokes each
    /// recognized line came from.
    ///
    /// The pass used to cut the ink into lines itself (`LineGrouper`) and send
    /// Vision one crop per line. That is why beautification caught roughly one
    /// word in ten: a crop of a single short word is a picture with no context,
    /// which is the hardest thing there is to read, and any group whose box
    /// wasn't wider than it was tall — one word, one number, a name — was
    /// discarded before Vision ever saw it. Vision segments lines itself, far
    /// better than a bounding-box heuristic can, and reads a whole page of
    /// handwriting with the language model working across it. So it gets the
    /// whole page, and the boxes it hands back are matched to the ink underneath.
    private func recognize(
        _ drawing: PKDrawing, settings: BeautifySettings, pageSize: CGSize
    ) async -> RecognitionPass {
        let strokes = drawing.strokes
        let boxes = strokes.map(\.renderBounds)
        var pass = RecognitionPass()

        let inked = boxes.filter { !$0.isNull && !$0.isEmpty }
        guard !inked.isEmpty else { return pass }
        let content = inked.reduce(CGRect.null) { $0.union($1) }
        let padding = max(12, Self.medianHeight(of: inked) * 0.5)
        let region = content.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: pageSize))
        guard region.width > 8, region.height > 8 else { return pass }

        pass.askedRecognizer = true
        // Read at the size Vision likes; if that comes back with nothing, read it
        // again much larger before giving up. A single fixed scale is why small or
        // cramped writing read as nothing at all.
        var found: [OCRService.Line] = []
        for scale in Self.renderScales(for: content, in: region) {
            let image = Self.recognitionImage(
                of: drawing, region: region, scale: scale,
                minimumInkWidth: Self.recognitionInkWidth(for: inked)
            )
            found = await recognizeLine(image, settings.language)
            if !found.isEmpty { break }
        }
        guard !found.isEmpty else { return pass }

        var claimed = Set<Int>()
        for line in found {
            let text = line.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let rect = Self.pageRect(forVisionBox: line.boundingBox, in: region)
            let indices = Self.strokes(boxes, inside: rect, excluding: claimed)
            guard !indices.isEmpty else { continue }
            let bounds = indices.reduce(CGRect.null) { $0.union(boxes[$1]) }
            // Vision found words here, so this is writing — the only thing left to
            // rule out is ink far too tall to be a line of it (a big diagram that
            // happens to contain a label).
            guard Self.isWritingLine(bounds, pageSize: pageSize) else { continue }
            claimed.formUnion(indices)
            pass.lines.append(RecognizedLine(
                text: text,
                bounds: bounds,
                strokeIndices: indices.sorted(),
                meanForce: Self.meanForce(of: indices.map { strokes[$0] })
            ))
        }
        return pass
    }

    /// A Vision box (normalized, origin bottom-left) as a rectangle in the page's
    /// own logical space.
    static func pageRect(forVisionBox box: CGRect, in region: CGRect) -> CGRect {
        CGRect(
            x: region.minX + box.minX * region.width,
            y: region.minY + (1 - box.maxY) * region.height,
            width: box.width * region.width,
            height: box.height * region.height
        )
    }

    /// Which strokes a recognized line is made of: the ones whose centre sits
    /// inside its box, generously grown vertically because Vision's box hugs the
    /// x-height and misses ascenders, descenders and the dot on an i.
    static func strokes(
        _ boxes: [CGRect], inside rect: CGRect, excluding claimed: Set<Int>
    ) -> [Int] {
        // Grown enough for ascenders, descenders and the dot on an i — and no
        // further. A band 120% taller than the line reached into the lines above
        // and below and claimed their ink; those lines were then left with no
        // strokes of their own and dropped, which is most of what "about half of
        // it gets read" was.
        let grown = rect.insetBy(dx: -rect.height * 0.25, dy: -rect.height * 0.45)
        return boxes.indices.filter { index in
            guard !claimed.contains(index) else { return false }
            let box = boxes[index]
            guard !box.isNull, !box.isEmpty else { return false }
            return grown.contains(CGPoint(x: box.midX, y: box.midY))
        }
    }

    static func medianHeight(of boxes: [CGRect]) -> CGFloat {
        guard !boxes.isEmpty else { return 0 }
        let heights = boxes.map(\.height).sorted()
        return heights[heights.count / 2]
    }

    /// The image Vision actually reads: the line's ink re-inked to solid black on
    /// an OPAQUE WHITE page.
    ///
    /// `PKDrawing.image(from:scale:)` hands back the ink in its own colour on a
    /// TRANSPARENT background. Recognition on that is a coin toss — flattening the
    /// alpha can put dark ink on a dark field (and on a dark theme the ink is light
    /// to begin with), so passes came back with no text at all and nothing was ever
    /// typeset. Forcing black-on-white is what makes beautification fire reliably.
    static func recognitionImage(
        of drawing: PKDrawing, region: CGRect, scale: CGFloat, minimumInkWidth: CGFloat = 0
    ) -> UIImage {
        let inked = PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(
                // Always the PEN, whatever wrote it. A marker or a highlighter
                // renders as a wide translucent band whose letters bleed into each
                // other — legible to a person, unreadable to Vision.
                ink: PKInk(.pen, color: .black),
                path: Self.thickened(stroke.path, to: minimumInkWidth),
                transform: stroke.transform,
                mask: stroke.mask
            )
        })
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let size = region.size
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            inked.image(from: region, scale: scale)
                .draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The longest side we will hand Vision. Beyond this the crop costs more time
    /// than the extra detail buys, and a whole page of writing at a per-line scale
    /// would run into the tens of thousands of pixels.
    static let maximumCropSide: CGFloat = 4400

    /// Small writing needs more pixels; huge writing needs fewer. Aims for a
    /// ~46 px x-height, which is Vision's sweet spot for handwriting, then backs
    /// off if that would make the crop enormous.
    static func renderScale(for content: CGRect, in region: CGRect) -> CGFloat {
        let target: CGFloat = 46
        let height = max(content.height, 1)
        // A block of several lines: aim at the height of ONE of them.
        let lines = max(1, (height / max(minimumLineHeight * 2, 1)).rounded(.down))
        let ideal = target / max(height / lines, 1)
        let ceiling = maximumCropSide / max(region.width, region.height, 1)
        return min(max(min(ideal, ceiling), 1), 10)
    }

    /// The scales a region is attempted at, in order: the sweet spot first, then a
    /// much larger crop for writing that came back blank.
    static func renderScales(for content: CGRect, in region: CGRect) -> [CGFloat] {
        let first = renderScale(for: content, in: region)
        let second = min(first * 2.2, 14)
        return second > first * 1.2 ? [first, second] : [first]
    }

    /// A floor on how wide the ink is drawn for RECOGNITION only. A fineliner at
    /// 0.5 pt all but disappears once the crop is rasterized, and Vision reads a
    /// disappearing letter as no letter. Scaled off the typical line height so big
    /// writing doesn't turn into a solid blob.
    static func recognitionInkWidth(for boxes: [CGRect]) -> CGFloat {
        max(1.6, medianHeight(of: boxes) * 0.07)
    }

    /// The same path with every point at least `width` across. Returns the path
    /// untouched when it's already thick enough, or when no floor was asked for.
    static func thickened(_ path: PKStrokePath, to width: CGFloat) -> PKStrokePath {
        guard width > 0 else { return path }
        let points = Array(path)
        guard points.contains(where: { $0.size.width < width || $0.size.height < width })
        else { return path }
        let widened = points.map { point in
            PKStrokePoint(
                location: point.location,
                timeOffset: point.timeOffset,
                size: CGSize(
                    width: max(point.size.width, width),
                    height: max(point.size.height, width)
                ),
                opacity: max(point.opacity, 1),
                force: point.force,
                azimuth: point.azimuth,
                altitude: point.altitude
            )
        }
        return PKStrokePath(controlPoints: widened, creationDate: path.creationDate)
    }

    /// Rejects diagrams and doodles: a line of writing is neither a hairline nor
    /// half the page tall, and it runs across rather than down.
    static func looksLikeWriting(_ bounds: CGRect) -> Bool {
        guard !bounds.isNull, bounds.height >= minimumLineHeight,
              bounds.height <= maximumLineHeight else { return false }
        return bounds.width >= bounds.height * 0.55
    }

    /// Whether ink that Vision read words out of really is a line of writing.
    ///
    /// This test used to be a fixed height in page points, and that is exactly why
    /// beautification "only worked zoomed in". Zooming lays the page out bigger
    /// without changing its logical size, so the same hand covers FEWER logical
    /// points — and only then did a line fit under a flat 130-point ceiling. At
    /// the page's natural size a comfortable hand is well over it, and every line
    /// was thrown away after being read perfectly.
    ///
    /// A line is judged against the page it is on instead, and tall ink is judged
    /// on its shape: writing runs across the page, a diagram runs down it.
    static func isWritingLine(_ bounds: CGRect, pageSize: CGSize) -> Bool {
        guard !bounds.isNull, !bounds.isEmpty, bounds.height >= minimumLineHeight else {
            return false
        }
        guard bounds.height <= lineHeightCeiling(pageSize: pageSize) else { return false }
        // Comfortably small: no line of writing that fits in a fifth of a page
        // needs defending against.
        guard bounds.height > maximumLineHeight else { return true }
        return bounds.width >= bounds.height * 0.55
    }

    /// The tallest a single line may be on this page.
    static func lineHeightCeiling(pageSize: CGSize) -> CGFloat {
        max(maximumLineHeight, pageSize.height * 0.22)
    }

    static func meanForce(of strokes: [PKStroke]) -> Double {
        var total = 0.0
        var count = 0
        for stroke in strokes {
            for point in stroke.path {
                total += Double(point.force)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        // PKStrokePoint.force is in 0…~4 for Pencil; normalize to 0…1.
        return min(1, total / Double(count) / 2.5)
    }

}
