import NotesModels
import SwiftUI

/// Renders a function-plot block's curve — axes (labeled) and the sampled
/// curve(s) — from a typed expression. Shared by the editor's own element and
/// the read-only viewer/export (`PageContentView`), same reuse `CodeBlockText`
/// established, so a note looks the same on both.
///
/// Parsing and sampling (`FunctionExpression`/`FunctionPlotSampler`, in
/// `NotesModels`) are pure and dependency-free; this is just the SwiftUI
/// `Canvas` drawing on top. A blank or unparseable expression just shows bare
/// (labeled) axes — no caption sitting in the middle of the box any more;
/// guidance lives in the editor's own field placeholders, where it's actually
/// next to what you're typing.
public struct FunctionPlotView: View {
    public let expression: String
    public let secondaryExpression: String?
    public let tertiaryExpression: String?
    public let mode: PlotMode
    public let window: Double
    public let lineColor: Color
    public let axisColor: Color
    /// 3D mode only: the user's own name for each axis (defaults "X"/"Y"/"Z").
    public let axisXLabel: String
    public let axisYLabel: String
    public let axisZLabel: String

    public init(
        expression: String, secondaryExpression: String? = nil, tertiaryExpression: String? = nil,
        mode: PlotMode, window: Double, lineColor: Color, axisColor: Color,
        axisXLabel: String = "X", axisYLabel: String = "Y", axisZLabel: String = "Z"
    ) {
        self.expression = expression
        self.secondaryExpression = secondaryExpression
        self.tertiaryExpression = tertiaryExpression
        self.mode = mode
        self.window = max(window, 0.01)
        self.lineColor = lineColor
        self.axisColor = axisColor
        self.axisXLabel = axisXLabel
        self.axisYLabel = axisYLabel
        self.axisZLabel = axisZLabel
    }

    private var runs: [[CGPoint]] {
        (try? Self.sample(
            expression: expression, secondary: secondaryExpression, tertiary: tertiaryExpression,
            mode: mode, window: window
        )) ?? []
    }

    public var body: some View {
        Canvas { context, size in
            if mode == .threeD {
                draw3DAxes(in: &context, size: size)
            } else {
                drawAxes(in: &context, size: size)
            }
            drawCurve(runs, in: &context, size: size)
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

    private func drawAxes(in context: inout GraphicsContext, size: CGSize) {
        let origin = toView(.zero, size: size)
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: origin.y))
        axes.addLine(to: CGPoint(x: size.width, y: origin.y))
        axes.move(to: CGPoint(x: origin.x, y: 0))
        axes.addLine(to: CGPoint(x: origin.x, y: size.height))
        context.stroke(axes, with: .color(axisColor.opacity(0.6)), lineWidth: 1)

        // The on-screen axes are always Cartesian x/y regardless of the
        // function's own variable (r/θ, t) — that's what's actually drawn.
        context.draw(
            Text("x").font(Self.labelFont).foregroundStyle(axisColor.opacity(0.75)),
            at: CGPoint(x: max(size.width - 10, origin.x + 12), y: origin.y - 11)
        )
        context.draw(
            Text("y").font(Self.labelFont).foregroundStyle(axisColor.opacity(0.75)),
            at: CGPoint(x: origin.x + 11, y: max(10, origin.y - 12))
        )
    }

    /// Three axis lines from the origin out to `window` along each direction,
    /// in a fixed isometric projection — no rotation gesture, just a stable,
    /// readable angle. Labeled with whatever the user named each axis.
    private func draw3DAxes(in context: inout GraphicsContext, size: CGSize) {
        let origin = toView(FunctionPlotSampler.isometric(x: 0, y: 0, z: 0), size: size)
        let xEnd = toView(FunctionPlotSampler.isometric(x: window, y: 0, z: 0), size: size)
        let yEnd = toView(FunctionPlotSampler.isometric(x: 0, y: window, z: 0), size: size)
        let zEnd = toView(FunctionPlotSampler.isometric(x: 0, y: 0, z: window), size: size)

        for end in [xEnd, yEnd, zEnd] {
            var axis = Path()
            axis.move(to: origin)
            axis.addLine(to: end)
            context.stroke(axis, with: .color(axisColor.opacity(0.7)), lineWidth: 1.4)
        }
        context.draw(Text(axisXLabel).font(Self.labelFont).foregroundStyle(axisColor), at: xEnd)
        context.draw(Text(axisYLabel).font(Self.labelFont).foregroundStyle(axisColor), at: yEnd)
        context.draw(Text(axisZLabel).font(Self.labelFont).foregroundStyle(axisColor), at: zEnd)
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
    /// filled in. Axes-only is a normal, valid state, not an error one.
    private static func sample(
        expression: String, secondary: String?, tertiary: String?, mode: PlotMode, window: Double
    ) throws -> [[CGPoint]] {
        switch mode {
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
