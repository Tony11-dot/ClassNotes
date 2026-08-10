import CoreGraphics
import Foundation
import NotesModels

/// Turning recognized lines into typeset elements.
///
/// Pure: no canvas, no Vision, no model — so the placement and merge rules are
/// pinned by tests rather than inferred from what happened to appear on a page.
extension LiveBeautifier {
// MARK: - Planning (pure)

/// Turns recognized lines into element inserts/updates. Pure: no canvas, no
/// Vision, no model — so the placement and merge rules are pinned by tests.
static func plan(
    lines: [RecognizedLine],
    existing: [BeautifiedRun],
    settings: BeautifySettings,
    fontName: String,
    colorHex: String?,
    pageSize: CGSize,
    metrics: TextMetrics
) -> BeautifyPlan {
    var plan = BeautifyPlan()
    var runs = existing

    for line in lines {
        let typeSize = settings.typeSize(forInkHeight: line.bounds.height)
        let bold = settings.dynamicBold && line.meanForce > 0.5
        let spacing = settings.effectiveLineSpacing
        let frame = BeautifyLayout.frame(
            inkBounds: line.bounds,
            text: line.text,
            typeSize: typeSize,
            lineSpacing: spacing,
            metrics: metrics,
            in: pageSize
        )

        if let index = runs.firstIndex(where: {
            BeautifyLayout.continues(
                existing: $0.inkBounds.isNull ? $0.frame : $0.inkBounds,
                incoming: line.bounds,
                typeSize: typeSize
            )
        }) {
            // The student kept writing on a line that's already typeset.
            let joined = runs[index].text + " " + line.text
            let merged = BeautifyLayout.merged(
                existing: runs[index].frame, incoming: frame, text: joined,
                typeSize: typeSize, lineSpacing: spacing,
                metrics: metrics, in: pageSize
            )
            runs[index].text = joined
            runs[index].frame = merged
            runs[index].inkBounds = runs[index].inkBounds.isNull
                ? line.bounds
                : runs[index].inkBounds.union(line.bounds)
            let element = PageElement(
                id: runs[index].elementID, kind: .text,
                x: merged.minX, y: merged.minY, width: merged.width, height: merged.height,
                text: joined, fontName: fontName, textColorHex: colorHex,
                fontSize: typeSize, lineSpacing: spacing, isBold: bold
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
                fontSize: typeSize, lineSpacing: spacing, isBold: bold
            )
            plan.inserts.append(element)
            runs.append(BeautifiedRun(
                elementID: element.id, frame: frame, text: line.text,
                inkBounds: line.bounds
            ))
        }
        plan.consumedStrokes.formUnion(line.strokeIndices)
    }

    plan.runs = runs
    return plan
}}
