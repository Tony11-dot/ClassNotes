import NotesModels
import SwiftUI

/// Renders a function-plot block's curve — axes (labeled, ticked, arrowed) and
/// the sampled curve(s) — from a typed expression. Shared by the editor's own
/// element and the read-only viewer/export (`PageContentView`), same reuse
/// `CodeBlockText` established, so a note looks the same on both.
///
/// Parsing and sampling (`FunctionExpression`/`FunctionPlotSampler`, in
/// `NotesModels`) are pure and dependency-free; this is just the SwiftUI
/// `Canvas` drawing on top. A blank expression just shows bare (labeled)
/// axes — no caption sitting in the middle of the box; guidance lives in the
/// editor's own field placeholders, where it's actually next to what you're
/// typing. A non-blank expression that fails to parse/sample shows a small
/// corner badge instead — silence there used to be indistinguishable from "the
/// expression field does nothing".
public struct FunctionPlotView: View {
    public let expression: String
    public let secondaryExpression: String?
    public let tertiaryExpression: String?
    public let mode: PlotMode
    public let window: Double
    public let lineColor: Color
    public let axisColor: Color
    public let axisX: AxisDisplay
    public let axisY: AxisDisplay
    public let axisZ: AxisDisplay

    public init(
        expression: String, secondaryExpression: String? = nil, tertiaryExpression: String? = nil,
        mode: PlotMode, window: Double, lineColor: Color, axisColor: Color,
        axisX: AxisDisplay = AxisDisplay(label: "X"),
        axisY: AxisDisplay = AxisDisplay(label: "Y"),
        axisZ: AxisDisplay = AxisDisplay(label: "Z")
    ) {
        self.expression = expression
        self.secondaryExpression = secondaryExpression
        self.tertiaryExpression = tertiaryExpression
        self.mode = mode
        self.window = max(window, 0.01)
        self.lineColor = lineColor
        self.axisColor = axisColor
        self.axisX = axisX
        self.axisY = axisY
        self.axisZ = axisZ
    }

    private var runs: [[CGPoint]] {
        (try? Self.sample(
            expression: expression, secondary: secondaryExpression, tertiary: tertiaryExpression,
            mode: mode, window: window
        )) ?? []
    }

    /// Something was typed but nothing plotted — a typo, or (in 3D) not all
    /// three of x(t)/y(t)/z(t) filled in yet. Distinct from a genuinely blank,
    /// not-yet-started block, which shows nothing extra at all.
    private var hasUnresolvedInput: Bool {
        guard mode != .axis else { return false }
        let primary = !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let secondary = !(secondaryExpression ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tertiary = !(tertiaryExpression ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let anyTyped = mode.needsTertiaryExpression ? (primary || secondary || tertiary) : primary
        return anyTyped && runs.isEmpty
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                switch mode {
                case .axis: drawSingleAxis(in: &context, size: size)
                case .threeD: draw3DAxes(in: &context, size: size)
                default: drawAxes(in: &context, size: size)
                }
                drawCurve(runs, in: &context, size: size)
            }
            if hasUnresolvedInput {
                Circle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 8, height: 8)
                    .padding(6)
                    .accessibilityLabel("Can't plot this expression")
            }
        }
    }

    /// Math space `(-window...window)` on both axes maps to the box, y
    /// flipped since math points up and the canvas points down.
    private func toView(_ point: CGPoint, size: CGSize) -> CGPoint {
        let scaleX = size.width / CGFloat(window * 2)
        let scaleY = size.height / CGFloat(window * 2)
        return CGPoint(
            x: size.width / 2 + CGFloat(point.x) * scaleX,
            y: size.height / 2 - CGFloat(point.y) * scaleY
        )
    }

    private static let labelFont = Font.system(size: 11, weight: .semibold)
    private static let tickFont = Font.system(size: 8, weight: .regular)

    private func drawAxes(in context: inout GraphicsContext, size: CGSize) {
        let origin = toView(.zero, size: size)

        var xAxis = Path()
        xAxis.move(to: CGPoint(x: 0, y: origin.y))
        xAxis.addLine(to: CGPoint(x: size.width, y: origin.y))
        context.stroke(xAxis, with: .color(axisColor.opacity(0.6)), lineWidth: 1)
        let xTip = CGPoint(x: size.width, y: origin.y)
        drawArrowhead(at: xTip, from: origin, in: &context)
        drawTicksAlongX(axisX, origin: origin, size: size, in: &context)
        // Horizontal axis: the label sits BESIDE the arrow tip.
        context.draw(
            Text(axisX.displayLabel).font(Self.labelFont).foregroundStyle(axisColor.opacity(0.85)),
            at: CGPoint(x: max(size.width - 14, origin.x + 14), y: origin.y - 11)
        )

        var yAxis = Path()
        yAxis.move(to: CGPoint(x: origin.x, y: size.height))
        yAxis.addLine(to: CGPoint(x: origin.x, y: 0))
        context.stroke(yAxis, with: .color(axisColor.opacity(0.6)), lineWidth: 1)
        let yTip = CGPoint(x: origin.x, y: 0)
        drawArrowhead(at: yTip, from: origin, in: &context)
        drawTicksAlongY(axisY, origin: origin, size: size, in: &context)
        // Vertical axis: the label sits ABOVE the arrow tip.
        context.draw(
            Text(axisY.displayLabel).font(Self.labelFont).foregroundStyle(axisColor.opacity(0.85)),
            at: CGPoint(x: origin.x + 14, y: max(10, 10))
        )
    }

    /// A bare number line: one horizontal axis, ticked and arrowed, using the
    /// X axis's own settings (name/unit/tick format/interval).
    private func drawSingleAxis(in context: inout GraphicsContext, size: CGSize) {
        let y = size.height / 2
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(line, with: .color(axisColor.opacity(0.6)), lineWidth: 1)
        let origin = CGPoint(x: size.width / 2, y: y)
        drawArrowhead(at: CGPoint(x: size.width, y: y), from: origin, in: &context)
        drawTicksAlongX(axisX, origin: origin, size: size, in: &context)
        context.draw(
            Text(axisX.displayLabel).font(Self.labelFont).foregroundStyle(axisColor.opacity(0.85)),
            at: CGPoint(x: max(size.width - 14, origin.x + 14), y: y - 11)
        )
    }

    /// Three axis lines from the origin out to `window` along each direction,
    /// in a fixed isometric projection — no rotation gesture, just a stable,
    /// readable angle. Each axis picks its OWN label placement rule from its
    /// own on-screen direction, since none of the three isometric axes are
    /// purely horizontal or vertical the way the 2D ones are.
    private func draw3DAxes(in context: inout GraphicsContext, size: CGSize) {
        let origin = toView(FunctionPlotSampler.isometric(x: 0, y: 0, z: 0), size: size)
        let xEnd = toView(FunctionPlotSampler.isometric(x: window, y: 0, z: 0), size: size)
        let yEnd = toView(FunctionPlotSampler.isometric(x: 0, y: window, z: 0), size: size)
        let zEnd = toView(FunctionPlotSampler.isometric(x: 0, y: 0, z: window), size: size)

        for (end, display) in [(xEnd, axisX), (yEnd, axisY), (zEnd, axisZ)] {
            var axis = Path()
            axis.move(to: origin)
            axis.addLine(to: end)
            context.stroke(axis, with: .color(axisColor.opacity(0.7)), lineWidth: 1.4)
            drawArrowhead(at: end, from: origin, in: &context)
            drawTicks(display, from: origin, to: end, valueAtTip: window, in: &context)

            let dx = end.x - origin.x, dy = end.y - origin.y
            let labelPoint: CGPoint = abs(dx) >= abs(dy)
                ? CGPoint(x: end.x + (dx >= 0 ? 16 : -16), y: end.y)
                : CGPoint(x: end.x, y: end.y - 12)
            context.draw(
                Text(display.displayLabel).font(Self.labelFont).foregroundStyle(axisColor),
                at: labelPoint
            )
        }
    }

    /// How close a tick may come to an axis's own arrowhead before it's
    /// skipped. The arrowhead's `headLength` is 8pt; a tick landing at or past
    /// that point renders its number sitting under/past the arrow itself — an
    /// axis is supposed to visibly END at the arrowhead, not keep sprouting
    /// labelled values past it. Only the POSITIVE end of each axis has an
    /// arrowhead (the negative side is a bare line), so only ticks approaching
    /// that end are ever skipped.
    private static let arrowheadClearance: CGFloat = 14

    /// A filled triangle at `tip`, pointing along the `from → tip` direction.
    private func drawArrowhead(at tip: CGPoint, from origin: CGPoint, in context: inout GraphicsContext) {
        let dx = tip.x - origin.x, dy = tip.y - origin.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let perpX = -uy, perpY = ux
        let headLength: CGFloat = 8
        let headWidth: CGFloat = 5
        let back = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: back.x + perpX * headWidth, y: back.y + perpY * headWidth))
        head.addLine(to: CGPoint(x: back.x - perpX * headWidth, y: back.y - perpY * headWidth))
        head.closeSubpath()
        context.fill(head, with: .color(axisColor.opacity(0.85)))
    }

    /// Tick marks + number labels along a straight segment from `origin`
    /// (value 0) to a point whose math-space value is `valueAtTip` — used for
    /// each 3D axis, which only ever runs 0...window in one direction.
    private func drawTicks(
        _ display: AxisDisplay, from origin: CGPoint, to tip: CGPoint,
        valueAtTip: Double, in context: inout GraphicsContext
    ) {
        guard abs(valueAtTip) > 0.0001 else { return }
        let interval = display.interval(window: abs(valueAtTip))
        let dx = tip.x - origin.x, dy = tip.y - origin.y
        let length = max(hypot(dx, dy), 0.0001)
        let perpX = -dy / length, perpY = dx / length
        let tickHalf: CGFloat = 4
        let clearanceT = length > 0 ? Self.arrowheadClearance / length : 0
        var value = interval
        while value <= abs(valueAtTip) + 0.0001 {
            let t = CGFloat(value / abs(valueAtTip))
            if t > 1 - clearanceT {
                value += interval
                continue
            }
            let point = CGPoint(x: origin.x + dx * t, y: origin.y + dy * t)
            drawTick(at: point, perpX: perpX, perpY: perpY, halfLength: tickHalf, label: display.tickFormat.label(for: value), in: &context)
            value += interval
        }
    }

    /// Ticks along a horizontal axis (the 2D x-axis, or the 1-axis number
    /// line), on both sides of the origin out to `window`.
    private func drawTicksAlongX(_ display: AxisDisplay, origin: CGPoint, size: CGSize, in context: inout GraphicsContext) {
        let interval = display.interval(window: window)
        var value = interval
        while value <= window + 0.0001 {
            for signedValue in [value, -value] {
                let point = toView(CGPoint(x: signedValue, y: 0), size: size)
                guard point.x >= 0, point.x <= size.width else { continue }
                if signedValue > 0, size.width - point.x < Self.arrowheadClearance { continue }
                drawTick(at: point, perpX: 0, perpY: 1, halfLength: 4, label: display.tickFormat.label(for: signedValue), in: &context)
            }
            value += interval
        }
    }

    /// Ticks along a vertical axis (the 2D y-axis), above and below the origin.
    private func drawTicksAlongY(_ display: AxisDisplay, origin: CGPoint, size: CGSize, in context: inout GraphicsContext) {
        let interval = display.interval(window: window)
        var value = interval
        while value <= window + 0.0001 {
            for signedValue in [value, -value] {
                let point = toView(CGPoint(x: 0, y: signedValue), size: size)
                guard point.y >= 0, point.y <= size.height else { continue }
                if signedValue > 0, point.y < Self.arrowheadClearance { continue }
                drawTick(at: point, perpX: 1, perpY: 0, halfLength: 4, label: display.tickFormat.label(for: signedValue), in: &context)
            }
            value += interval
        }
    }

    private func drawTick(
        at point: CGPoint, perpX: CGFloat, perpY: CGFloat, halfLength: CGFloat, label: String,
        in context: inout GraphicsContext
    ) {
        var tick = Path()
        tick.move(to: CGPoint(x: point.x - perpX * halfLength, y: point.y - perpY * halfLength))
        tick.addLine(to: CGPoint(x: point.x + perpX * halfLength, y: point.y + perpY * halfLength))
        context.stroke(tick, with: .color(axisColor.opacity(0.5)), lineWidth: 1)
        context.draw(
            Text(label).font(Self.tickFont).foregroundStyle(axisColor.opacity(0.55)),
            at: CGPoint(x: point.x + perpX * 11, y: point.y + perpY * 11)
        )
    }

    private func drawCurve(_ runs: [[CGPoint]], in context: inout GraphicsContext, size: CGSize) {
        for run in runs where run.count > 1 {
            var path = Path()
            path.move(to: toView(run[0], size: size))
            for point in run.dropFirst() {
                path.addLine(to: toView(point, size: size))
            }
            context.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    /// `[]` (never a throw the caller sees) for anything not fully specified —
    /// blank, a parse error, or (in 3D) fewer than all three of x(t)/y(t)/z(t)
    /// filled in. Axes-only is a normal, valid state, not an error one — the
    /// caller distinguishes "nothing typed yet" from "typed but broken" via
    /// `hasUnresolvedInput` for the small failure badge.
    private static func sample(
        expression: String, secondary: String?, tertiary: String?, mode: PlotMode, window: Double
    ) throws -> [[CGPoint]] {
        switch mode {
        case .axis:
            return []
        case .cartesianY:
            return FunctionPlotSampler.explicit(
                try FunctionExpression(expression, variable: mode.variableName), window: window, swapped: false
            )
        case .cartesianX:
            return FunctionPlotSampler.explicit(
                try FunctionExpression(expression, variable: mode.variableName), window: window, swapped: true
            )
        case .polar:
            return FunctionPlotSampler.polar(
                try FunctionExpression(expression, variable: mode.variableName), window: window
            )
        case .parametric:
            let xExpression = try FunctionExpression(expression, variable: mode.variableName)
            let yExpression = try FunctionExpression(secondary ?? "", variable: mode.variableName)
            return FunctionPlotSampler.parametric(x: xExpression, y: yExpression, window: window)
        case .threeD:
            let xText = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            let yText = (secondary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let zText = (tertiary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !xText.isEmpty, !yText.isEmpty, !zText.isEmpty else { return [] }
            let xExpression = try FunctionExpression(xText, variable: mode.variableName)
            let yExpression = try FunctionExpression(yText, variable: mode.variableName)
            let zExpression = try FunctionExpression(zText, variable: mode.variableName)
            return FunctionPlotSampler.parametric3D(x: xExpression, y: yExpression, z: zExpression, window: window)
        }
    }
}
