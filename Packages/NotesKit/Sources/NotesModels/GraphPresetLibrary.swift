import Foundation

/// Which class of "known graph" a preset belongs to, so the picker can filter
/// by what the user is actually studying instead of one long flat list.
public enum GraphSubject: String, CaseIterable, Codable, Sendable, Identifiable {
    case math, physics, cs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .math: "Math"
        case .physics: "Physics"
        case .cs: "CS"
        }
    }

    public var symbolName: String {
        switch self {
        case .math: "x.squareroot"
        case .physics: "atom"
        case .cs: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// One ready-made graph — everything `FunctionPlotSettingsSheet` needs to drop
/// straight into its draft. A fixed, hand-picked set of the curves students
/// actually reach for (`e^x`, `sin x`, a v-t line, `O(n log n)`) rather than a
/// blank expression field every time, with "Recent" (`ToolState
/// .recentGraphPresetIDs`) surfacing whichever of these someone actually uses.
public struct GraphPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let subject: GraphSubject
    public let mode: PlotMode
    public let expression: String
    public let secondaryExpression: String?
    public let axisXLabel: String?
    public let axisYLabel: String?
    public let axisXUnit: String?
    public let axisYUnit: String?
    public let window: Double

    public init(
        id: String, name: String, subject: GraphSubject, mode: PlotMode = .cartesianY,
        expression: String, secondaryExpression: String? = nil,
        axisXLabel: String? = nil, axisYLabel: String? = nil,
        axisXUnit: String? = nil, axisYUnit: String? = nil,
        window: Double = 10
    ) {
        self.id = id
        self.name = name
        self.subject = subject
        self.mode = mode
        self.expression = expression
        self.secondaryExpression = secondaryExpression
        self.axisXLabel = axisXLabel
        self.axisYLabel = axisYLabel
        self.axisXUnit = axisXUnit
        self.axisYUnit = axisYUnit
        self.window = window
    }
}

public enum GraphPresetLibrary {
    public static let all: [GraphPreset] = math + physics + cs

    public static func presets(for subject: GraphSubject?) -> [GraphPreset] {
        guard let subject else { return all }
        return all.filter { $0.subject == subject }
    }

    public static func preset(id: String) -> GraphPreset? {
        all.first { $0.id == id }
    }

    private static let math: [GraphPreset] = [
        GraphPreset(id: "math.exp", name: "eˣ", subject: .math, expression: "e^x", window: 4),
        GraphPreset(id: "math.sin", name: "sin(x)", subject: .math, expression: "sin(x)", window: 8),
        GraphPreset(id: "math.cos", name: "cos(x)", subject: .math, expression: "cos(x)", window: 8),
        GraphPreset(id: "math.tan", name: "tan(x)", subject: .math, expression: "tan(x)", window: 6),
        GraphPreset(id: "math.square", name: "x²", subject: .math, expression: "x^2", window: 6),
        GraphPreset(id: "math.sqrt", name: "√x", subject: .math, expression: "sqrt(x)", window: 8),
        GraphPreset(id: "math.reciprocal", name: "1/x", subject: .math, expression: "1/x", window: 6),
        GraphPreset(id: "math.ln", name: "ln(x)", subject: .math, expression: "ln(x)", window: 8)
    ]

    private static let physics: [GraphPreset] = [
        GraphPreset(
            id: "physics.positionConstV", name: "Position, constant velocity", subject: .physics,
            expression: "2*x + 1", axisXLabel: "t", axisYLabel: "x", axisXUnit: "s", axisYUnit: "m", window: 8
        ),
        GraphPreset(
            id: "physics.velocityConstA", name: "Velocity, constant acceleration", subject: .physics,
            expression: "1.5*x + 3", axisXLabel: "t", axisYLabel: "v", axisXUnit: "s", axisYUnit: "m/s", window: 8
        ),
        GraphPreset(
            id: "physics.constantA", name: "Constant acceleration", subject: .physics,
            expression: "4", axisXLabel: "t", axisYLabel: "a", axisXUnit: "s", axisYUnit: "m/s²", window: 8
        ),
        GraphPreset(
            id: "physics.freeFall", name: "Free-fall position", subject: .physics,
            expression: "20*x - 4.9*x^2", axisXLabel: "t", axisYLabel: "x", axisXUnit: "s", axisYUnit: "m", window: 6
        ),
        GraphPreset(
            id: "physics.shm", name: "Simple harmonic motion", subject: .physics,
            expression: "3*sin(2*x)", axisXLabel: "t", axisYLabel: "x", axisXUnit: "s", axisYUnit: "m", window: 8
        ),
        GraphPreset(
            id: "physics.projectile", name: "Projectile trajectory", subject: .physics,
            mode: .parametric, expression: "8*t", secondaryExpression: "10*t - 4.9*t^2",
            axisXLabel: "x", axisYLabel: "y", axisXUnit: "m", axisYUnit: "m", window: 12
        )
    ]

    private static let cs: [GraphPreset] = [
        GraphPreset(id: "cs.linear", name: "O(n)", subject: .cs, expression: "x", window: 10),
        GraphPreset(id: "cs.logLinear", name: "O(n log n)", subject: .cs, expression: "x*ln(x)", window: 10),
        GraphPreset(id: "cs.quadratic", name: "O(n²)", subject: .cs, expression: "x^2", window: 6),
        GraphPreset(id: "cs.exponential", name: "O(2ⁿ)", subject: .cs, expression: "2^x", window: 6),
        GraphPreset(id: "cs.logarithmic", name: "O(log n)", subject: .cs, expression: "ln(x)", window: 10),
        GraphPreset(id: "cs.sigmoid", name: "Sigmoid", subject: .cs, expression: "1/(1+e^(-x))", window: 6)
    ]
}
