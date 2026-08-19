import NotesModels
import SwiftUI

/// Renders a function-plot block's curve — axes, light gridlines, and the
/// sampled curve(s) — from a typed expression. Shared by the editor's own
/// element and the read-only viewer/export (`PageContentView`), same reuse
/// `CodeBlockText` established, so a note looks the same on both.
///
/// Parsing and sampling (`FunctionExpression`/`FunctionPlotSampler`, in
/// `NotesModels`) are pure and dependency-free; this is just the SwiftUI
/// `Canvas` drawing on top. An expression that won't parse degrades to a
/// friendly caption inside the box rather than a crash or a blank square —
/// same never-lose-data posture as `PageElement.Kind.unknown`.
public struct FunctionPlotView: View {
    public let expression: String
    public let secondaryExpression: String?
    public let mode: PlotMode
    public let window: Double
    public let lineColor: Color
    public let axisColor: Color

    public init(
        expression: String, secondaryExpression: String? = nil, mode: PlotMode, window: Double,
        lineColor: Color, axisColor: Color
    ) {
        self.expression = expression
        self.secondaryExpression = secondaryExpression
        self.mode = mode
        self.window = max(window, 0.01)
        self.lineColor = lineColor
        self.axisColor = axisColor
    }

    private var isBlank: Bool {
        let primaryEmpty = expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard mode.needsSecondaryExpression else { return primaryEmpty }
        let secondaryEmpty = (secondaryExpression ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return primaryEmpty && secondaryEmpty
    }

    private var runs: [[CGPoint]]? {
        try? Self.sample(expression: expression, secondary: secondaryExpression, mode: mode, window: window)
    }

    public var body: some View {
        ZStack {
            Canvas { context, size in
                drawAxes(in: &context, size: size)
                if let runs {
                    drawCurve(runs, in: &context, size: size)
                }
            }
            if runs == nil {
                Text(isBlank ? "Type a function, e.g. \(mode.example)" : "Can't plot — check your expression")
                    .font(.dsCaption)
                    .foregroundStyle(lineColor.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(14)
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

    private func drawAxes(in context: inout GraphicsContext, size: CGSize) {
        let origin = toView(.zero, size: size)
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: origin.y))
        axes.addLine(to: CGPoint(x: size.width, y: origin.y))
        axes.move(to: CGPoint(x: origin.x, y: 0))
        axes.addLine(to: CGPoint(x: origin.x, y: size.height))
        context.stroke(axes, with: .color(axisColor.opacity(0.6)), lineWidth: 1)
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

    private static func sample(
        expression: String, secondary: String?, mode: PlotMode, window: Double
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
        }
    }
}
