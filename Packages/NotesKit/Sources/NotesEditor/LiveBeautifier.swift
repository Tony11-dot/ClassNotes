import CoreGraphics
import Foundation
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
    /// Reads one rendered line of ink back as text. Injected so the whole pass —
    /// grouping, planning, wiping, merging — can be driven in tests without Vision,
    /// which is why the plumbing went unverified while it was hardwired.
    typealias LineRecognizer = @Sendable (UIImage, String) async -> String

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
    static let visionRecognizer: LineRecognizer = { image, language in
        (try? await OCRService().recognizeText(in: image, languages: [language])) ?? ""
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
            pageSize: pageSize
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

    private func recognize(
        _ drawing: PKDrawing, settings: BeautifySettings, pageSize: CGSize
    ) async -> RecognitionPass {
        let strokes = drawing.strokes
        let boxes = strokes.map(\.renderBounds)
        var pass = RecognitionPass()

        for indices in LineGrouper.lines(of: boxes) {
            let bounds = indices.reduce(CGRect.null) { $0.union(boxes[$1]) }
            guard Self.looksLikeWriting(bounds) else { continue }
            let lineDrawing = PKDrawing(strokes: indices.map { strokes[$0] })
            let padding = max(10, bounds.height * 0.35)
            let region = bounds.insetBy(dx: -padding, dy: -padding)
                .intersection(CGRect(origin: .zero, size: pageSize))
            guard region.width > 4, region.height > 4 else { continue }

            let image = Self.recognitionImage(
                of: lineDrawing, region: region, scale: Self.renderScale(for: bounds)
            )
            pass.askedRecognizer = true
            let text = await recognizeLine(image, settings.language)
            let cleaned = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            pass.lines.append(RecognizedLine(
                text: cleaned,
                bounds: bounds,
                strokeIndices: indices,
                meanForce: Self.meanForce(of: indices.map { strokes[$0] })
            ))
        }
        return pass
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
        of drawing: PKDrawing, region: CGRect, scale: CGFloat
    ) -> UIImage {
        let inked = PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(
                ink: PKInk(stroke.ink.inkType, color: .black),
                path: stroke.path,
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

    /// Small writing needs more pixels; huge writing needs fewer. Keeps the crop
    /// around 180 px tall, which is Vision's sweet spot for handwriting.
    static func renderScale(for bounds: CGRect) -> CGFloat {
        let target: CGFloat = 180
        let height = max(bounds.height, 1)
        return min(max(target / height, 2), 8)
    }

    /// Rejects diagrams and doodles: a line of writing is neither a hairline nor
    /// half the page tall, and it runs across rather than down.
    static func looksLikeWriting(_ bounds: CGRect) -> Bool {
        guard !bounds.isNull, bounds.height >= minimumLineHeight,
              bounds.height <= maximumLineHeight else { return false }
        return bounds.width >= bounds.height * 0.55
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

    // MARK: - Planning (pure)

    /// Turns recognized lines into element inserts/updates. Pure: no canvas, no
    /// Vision, no model — so the placement and merge rules are pinned by tests.
    static func plan(
        lines: [RecognizedLine],
        existing: [BeautifiedRun],
        settings: BeautifySettings,
        fontName: String,
        colorHex: String?,
        pageSize: CGSize
    ) -> BeautifyPlan {
        var plan = BeautifyPlan()
        var runs = existing

        for line in lines {
            let typeSize = settings.typeSize(forInkHeight: line.bounds.height)
            let bold = settings.dynamicBold && line.meanForce > 0.5
            let frame = BeautifyLayout.frame(
                inkBounds: line.bounds,
                typeSize: typeSize,
                lineSpacing: settings.lineSpacing,
                characterCount: line.text.count,
                in: pageSize
            )

            if let index = runs.firstIndex(where: {
                BeautifyLayout.continues(existing: $0.frame, incoming: frame, typeSize: typeSize)
            }) {
                // The student kept writing on a line that's already typeset.
                let joined = runs[index].text + " " + line.text
                let merged = BeautifyLayout.merged(
                    existing: runs[index].frame, incoming: frame, in: pageSize
                )
                runs[index].text = joined
                runs[index].frame = merged
                let element = PageElement(
                    id: runs[index].elementID, kind: .text,
                    x: merged.minX, y: merged.minY, width: merged.width, height: merged.height,
                    text: joined, fontName: fontName, textColorHex: colorHex,
                    fontSize: typeSize, isBold: bold
                )
                // One line can only join one run per pass; replace any earlier
                // update for the same element so the text doesn't double up.
                plan.updates.removeAll { $0.id == element.id }
                plan.updates.append(element)
            } else {
                let element = PageElement(
                    kind: .text,
                    x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                    text: line.text, fontName: fontName, textColorHex: colorHex,
                    fontSize: typeSize, isBold: bold
                )
                plan.inserts.append(element)
                runs.append(BeautifiedRun(elementID: element.id, frame: frame, text: line.text))
            }
            plan.consumedStrokes.formUnion(line.strokeIndices)
        }

        plan.runs = runs
        return plan
    }
}
