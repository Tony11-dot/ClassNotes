import CoreGraphics
import Foundation

/// What kind of curve a function-plot block draws, and which variable its
/// expression(s) are written in terms of.
public enum PlotMode: String, Sendable, CaseIterable, Identifiable, Codable {
    /// `y = f(x)`.
    case cartesianY
    /// `x = f(y)` — the same explicit form with the axes swapped.
    case cartesianX
    /// `r = f(θ)`.
    case polar
    /// `x(t)`, `y(t)` traced together over a shared parameter — how a line,
    /// circle or any hand-drawable curve that isn't a function of x or y (a
    /// vertical line, a loop) gets plotted at all.
    case parametric
    /// A labeled 3D coordinate frame (custom name per axis), drawn in a fixed
    /// isometric projection — optionally with an `x(t)`, `y(t)`, `z(t)`
    /// parametric curve/vector traced through it. No rotation gesture; moving
    /// the block itself covers "adjust it".
    case threeD

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cartesianY: "y = f(x)"
        case .cartesianX: "x = f(y)"
        case .polar: "r = f(θ)"
        case .parametric: "x(t), y(t)"
        case .threeD: "3D (x, y, z)"
        }
    }

    /// The variable the primary expression is written in terms of.
    public var variableName: String {
        switch self {
        case .cartesianY: "x"
        case .cartesianX: "y"
        case .polar: "theta"
        case .parametric, .threeD: "t"
        }
    }

    /// Whether a second field (`y(t)` alongside the primary `x(t)`) is shown.
    public var needsSecondaryExpression: Bool { self == .parametric || self == .threeD }

    /// 3D is the one mode with a THIRD field, `z(t)`.
    public var needsTertiaryExpression: Bool { self == .threeD }

    /// A friendly example shown as a placeholder before the user types
    /// anything, so an empty block reads as "waiting for input", not broken.
    public var example: String {
        switch self {
        case .cartesianY: "y = x^2"
        case .cartesianX: "x = y^2"
        case .polar: "r = sin(3*theta)"
        case .parametric: "x = cos(t), y = sin(t)"
        case .threeD: "x = cos(t), y = sin(t), z = t/3"
        }
    }
}

/// Why an expression couldn't be parsed — shown to the user so a typo reads as
/// "fix this" rather than a block that just silently draws nothing.
public enum FunctionExpressionError: Error, Equatable, Sendable {
    case empty
    case unexpectedCharacter(Character)
    case unexpectedToken(String)
    case unknownIdentifier(String)
    case mismatchedParentheses
}

/// A parsed, evaluatable arithmetic expression over a single variable.
///
/// Recursive-descent over the raw characters, no separate tokenizer pass —
/// same spirit as `CodeSyntaxHighlighter`: one small, dependency-free, fully
/// unit-testable type, no third-party package, works with no network at all.
/// Supports `+ - * / ^`, unary minus, parentheses, `sin cos tan sqrt abs ln
/// log exp min max floor ceil`, the constants `pi`/`e`, and simple implicit
/// multiplication (`2x`, `3(x+1)`, `2sin(x)`) — the common ways people
/// actually write these by hand. It does NOT resolve multi-character
/// implicit products with no operator between two identifiers (`xsin(x)`);
/// writing `x*sin(x)` or `x sin(x)`-with-a-space-removed-first still isn't
/// ambiguous the way that is, and covering it needs a real tokenizer this
/// doesn't try to be.
public struct FunctionExpression: Sendable {
    indirect enum Node: Sendable {
        case number(Double)
        case variable
        case negate(Node)
        case add(Node, Node)
        case subtract(Node, Node)
        case multiply(Node, Node)
        case divide(Node, Node)
        case power(Node, Node)
        case call(String, [Node])
    }

    private let root: Node

    public init(_ text: String, variable: String) throws {
        var parser = Parser(text: text, variable: variable)
        root = try parser.parseExpression()
        try parser.expectEnd()
    }

    /// Evaluates at `value`. `nil` for anything non-finite — NaN, infinite, a
    /// domain error like `sqrt(-1)` or `1/0` — so the sampler can read that as
    /// a gap in the curve rather than a crash.
    public func evaluate(_ value: Double) -> Double? {
        let result = Self.evaluate(root, variable: value)
        return result.isFinite ? result : nil
    }

    private static func evaluate(_ node: Node, variable: Double) -> Double {
        switch node {
        case .number(let n): n
        case .variable: variable
        case .negate(let a): -evaluate(a, variable: variable)
        case .add(let a, let b): evaluate(a, variable: variable) + evaluate(b, variable: variable)
        case .subtract(let a, let b): evaluate(a, variable: variable) - evaluate(b, variable: variable)
        case .multiply(let a, let b): evaluate(a, variable: variable) * evaluate(b, variable: variable)
        case .divide(let a, let b): evaluate(a, variable: variable) / evaluate(b, variable: variable)
        case .power(let a, let b): pow(evaluate(a, variable: variable), evaluate(b, variable: variable))
        case .call(let name, let args): apply(name, args.map { evaluate($0, variable: variable) })
        }
    }

    private static func apply(_ name: String, _ args: [Double]) -> Double {
        switch (name, args.count) {
        case ("sin", 1): sin(args[0])
        case ("cos", 1): cos(args[0])
        case ("tan", 1): tan(args[0])
        case ("sqrt", 1): sqrt(args[0])
        case ("abs", 1): abs(args[0])
        case ("ln", 1): log(args[0])
        case ("log", 1): log10(args[0])
        case ("exp", 1): exp(args[0])
        case ("floor", 1): floor(args[0])
        case ("ceil", 1): ceil(args[0])
        case ("min", 2): min(args[0], args[1])
        case ("max", 2): max(args[0], args[1])
        default: .nan
        }
    }

    /// Character-at-a-time recursive descent: expr → term (± term)*, term →
    /// unary (×÷ unary | implicit-multiply)*, unary → -unary | power, power →
    /// atom (^ unary)?, atom → number | identifier(-call) | ( expr ).
    private struct Parser {
        let chars: [Character]
        var index = 0
        let variable: String

        init(text: String, variable: String) {
            chars = Array(text.lowercased().filter { !$0.isWhitespace })
            self.variable = variable.lowercased()
        }

        private var current: Character? { index < chars.count ? chars[index] : nil }

        mutating func parseExpression() throws -> Node {
            guard !chars.isEmpty else { throw FunctionExpressionError.empty }
            return try parseAddSub()
        }

        mutating func expectEnd() throws {
            guard index >= chars.count else {
                throw FunctionExpressionError.unexpectedCharacter(chars[index])
            }
        }

        private mutating func parseAddSub() throws -> Node {
            var left = try parseMulDiv()
            while let c = current, c == "+" || c == "-" {
                index += 1
                let right = try parseMulDiv()
                left = c == "+" ? .add(left, right) : .subtract(left, right)
            }
            return left
        }

        private mutating func parseMulDiv() throws -> Node {
            var left = try parseUnary()
            while let c = current, c == "*" || c == "/" {
                index += 1
                let right = try parseUnary()
                left = c == "*" ? .multiply(left, right) : .divide(left, right)
            }
            // Implicit multiplication ("2x", "3(x+1)", "2sin(x)") — refusing
            // it would make the block feel broken for the most natural input.
            while let c = current, c.isLetter || c == "(" {
                let right = try parseUnary()
                left = .multiply(left, right)
            }
            return left
        }

        private mutating func parseUnary() throws -> Node {
            if current == "-" {
                index += 1
                return .negate(try parseUnary())
            }
            if current == "+" {
                index += 1
                return try parseUnary()
            }
            return try parsePower()
        }

        private mutating func parsePower() throws -> Node {
            let base = try parseAtom()
            if current == "^" {
                index += 1
                return .power(base, try parseUnary())
            }
            return base
        }

        private mutating func parseAtom() throws -> Node {
            guard let c = current else { throw FunctionExpressionError.unexpectedToken("end of expression") }
            if c == "(" {
                index += 1
                let inner = try parseAddSub()
                guard current == ")" else { throw FunctionExpressionError.mismatchedParentheses }
                index += 1
                return inner
            }
            if c.isNumber || c == "." {
                return .number(try parseNumber())
            }
            if c.isLetter {
                return try parseIdentifier()
            }
            throw FunctionExpressionError.unexpectedCharacter(c)
        }

        private mutating func parseNumber() throws -> Double {
            var text = ""
            while let c = current, c.isNumber || c == "." {
                text.append(c)
                index += 1
            }
            guard let value = Double(text) else { throw FunctionExpressionError.unexpectedToken(text) }
            return value
        }

        private mutating func parseIdentifier() throws -> Node {
            var name = ""
            while let c = current, c.isLetter || c.isNumber {
                name.append(c)
                index += 1
            }
            if current == "(" {
                index += 1
                var args = [try parseAddSub()]
                while current == "," {
                    index += 1
                    args.append(try parseAddSub())
                }
                guard current == ")" else { throw FunctionExpressionError.mismatchedParentheses }
                index += 1
                return .call(name, args)
            }
            if name == variable || (variable == "theta" && name == "θ") {
                return .variable
            }
            switch name {
            case "pi": return .number(.pi)
            case "e": return .number(M_E)
            default: throw FunctionExpressionError.unknownIdentifier(name)
            }
        }
    }
}

/// Samples a parsed expression into one or more point "runs" in math space
/// (not yet mapped to a page/pixel box) — split wherever the curve is
/// undefined or jumps too far between consecutive samples, so an asymptote
/// like `tan(x)` or `1/x` doesn't draw a straight connecting line across the
/// gap it isn't defined at.
public enum FunctionPlotSampler {
    public static let sampleCount = 400
    /// How many "windows" a jump between consecutive samples may span before
    /// it's treated as a break rather than a steep-but-continuous curve.
    private static let breakFactor = 4.0
    /// Samples further than this from center are treated as off to infinity
    /// (an asymptote) rather than real curve to draw.
    private static let boundFactor = 50.0

    public static func explicit(_ expression: FunctionExpression, window: Double, swapped: Bool) -> [[CGPoint]] {
        run(from: -window, to: window, window: window) { input in
            guard let output = expression.evaluate(input) else { return nil }
            return swapped ? CGPoint(x: output, y: input) : CGPoint(x: input, y: output)
        }
    }

    /// Two full turns (`0...4π`) so a curve whose period isn't a multiple of
    /// 2π (an odd-petalled rose, for instance) still closes.
    public static func polar(_ expression: FunctionExpression, window: Double) -> [[CGPoint]] {
        run(from: 0, to: 4 * Double.pi, window: window) { theta in
            guard let r = expression.evaluate(theta) else { return nil }
            return CGPoint(x: r * cos(theta), y: r * sin(theta))
        }
    }

    public static func parametric(
        x xExpression: FunctionExpression, y yExpression: FunctionExpression, window: Double
    ) -> [[CGPoint]] {
        run(from: -window, to: window, window: window) { t in
            guard let x = xExpression.evaluate(t), let y = yExpression.evaluate(t) else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    /// A vector/curve through 3D space, traced by a shared parameter and
    /// projected with `isometric(x:y:z:)` — the same fixed angle the 3D axes
    /// themselves are drawn at, so a plotted curve always sits correctly inside
    /// its own frame.
    public static func parametric3D(
        x xExpression: FunctionExpression, y yExpression: FunctionExpression,
        z zExpression: FunctionExpression, window: Double
    ) -> [[CGPoint]] {
        run(from: -window, to: window, window: window) { t in
            guard let x = xExpression.evaluate(t), let y = yExpression.evaluate(t),
                  let z = zExpression.evaluate(t) else { return nil }
            return isometric(x: x, y: y, z: z)
        }
    }

    /// A fixed isometric projection from math-space (x, y, z) onto the 2D plane
    /// — no rotation, just a stable, readable angle shared by the 3D axes and
    /// any curve plotted inside them.
    public static func isometric(x: Double, y: Double, z: Double) -> CGPoint {
        let cos30 = 0.8660254037844387
        let sin30 = 0.5
        // Y-up in this "math space", same as every other mode here — `toView`
        // flips it once, later, the same way it flips a 2D point's y.
        return CGPoint(x: (x - z) * cos30, y: y - (x + z) * sin30)
    }

    /// Shared sampling loop: walks `from...to` in `sampleCount` steps, asking
    /// `point(at:)` for each sample's math-space point (`nil` = undefined
    /// there), and breaks the current run whenever a sample is undefined, out
    /// of bounds, or jumps further than `breakFactor` windows from the last
    /// one.
    private static func run(from: Double, to: Double, window: Double, point: (Double) -> CGPoint?) -> [[CGPoint]] {
        guard window > 0, to > from else { return [] }
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        let bound = window * boundFactor
        let breakDistance = window * breakFactor
        let step = (to - from) / Double(sampleCount)
        var input = from
        var previous: CGPoint?
        for _ in 0...sampleCount {
            defer { input += step }
            guard let sample = point(input), abs(sample.x) <= bound, abs(sample.y) <= bound else {
                if !current.isEmpty { runs.append(current); current = [] }
                previous = nil
                continue
            }
            if let previous, hypot(sample.x - previous.x, sample.y - previous.y) > breakDistance {
                if !current.isEmpty { runs.append(current); current = [] }
            }
            current.append(sample)
            previous = sample
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
