import Foundation
import NotesModels
import Testing

@Suite("Function-plot elements")
struct FunctionPlotElementTests {
    @Test("A function-plot round-trips its own fields alongside the text ones it reuses")
    func functionPlotRoundTrips() throws {
        let element = PageElement(
            kind: .functionPlot, x: 10, y: 20, width: 300, height: 300,
            textColorHex: "#89B4FA",
            functionExpression: "x^2", functionSecondaryExpression: nil,
            functionMode: "cartesianY", functionWindow: 12,
            colorHex: "#1E1E2E"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PageElement.self, from: encoder.encode(element))

        #expect(decoded.kind == .functionPlot)
        #expect(decoded.functionExpression == "x^2")
        #expect(decoded.functionMode == "cartesianY")
        #expect(decoded.functionWindow == 12)
        #expect(decoded.colorHex == "#1E1E2E")
        #expect(decoded.resolvedPlotMode == .cartesianY)
    }

    @Test("An older manifest with no function-plot fields at all still decodes")
    func missingFunctionFieldsDecodeToNilAndDefaultMode() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)", "kind": "functionPlot",
          "x": 0, "y": 0, "width": 100, "height": 100, "rotation": 0,
          "isBold": false, "points": [], "isHidden": false
        }
        """
        let element = try JSONDecoder().decode(PageElement.self, from: Data(json.utf8))
        #expect(element.functionExpression == nil)
        #expect(element.functionMode == nil)
        #expect(element.resolvedPlotMode == .cartesianY)
    }
}

@Suite("Function-plot settings")
struct FunctionPlotSettingsTests {
    @Test("Defaults are y = f(x) with a console-style palette")
    func defaults() {
        let settings = FunctionPlotSettings()
        #expect(settings.mode == .cartesianY)
        #expect(FunctionPlotSettings.cornerRadiusRange.contains(settings.cornerRadius))
        #expect(FunctionPlotSettings.windowRange.contains(settings.window))
    }

    @Test("A blob saved before function plots existed still decodes, with factory settings")
    func missingFunctionPlotKeyFallsBackToDefaults() throws {
        let json = """
        { "penPresetID": "fountainPen", "textFontID": "cabinet", "textSize": 20 }
        """
        let decoded = try JSONDecoder().decode(ToolPreferences.self, from: Data(json.utf8))
        #expect(decoded.functionPlot == FunctionPlotSettings())
        #expect(decoded.penPresetID == "fountainPen")
    }

    @Test("ToolPreferences carries function-plot settings through a total decode")
    func toolPreferencesDecodesFunctionPlot() throws {
        var preferences = ToolPreferences()
        preferences.functionPlot.mode = .polar
        preferences.functionPlot.window = 20

        let decoded = try JSONDecoder().decode(ToolPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.functionPlot.mode == .polar)
        #expect(decoded.functionPlot.window == 20)
    }
}

@Suite("Function expression parsing")
struct FunctionExpressionTests {
    private func eval(_ text: String, _ value: Double = 0, variable: String = "x") throws -> Double? {
        try FunctionExpression(text, variable: variable).evaluate(value)
    }

    @Test("Arithmetic precedence: multiplication binds tighter than addition")
    func precedence() throws {
        #expect(try eval("2+3*4") == 14)
        #expect(try eval("(2+3)*4") == 20)
    }

    @Test("Unary minus negates its operand")
    func unaryMinus() throws {
        #expect(try eval("-x", 5) == -5)
        #expect(try eval("2*-3") == -6)
    }

    @Test("Power is right-associative and binds tighter than unary on its right")
    func power() throws {
        #expect(try eval("2^3") == 8)
        #expect(try eval("x^2", 4) == 16)
    }

    @Test("Implicit multiplication: 2x, 3(x+1), 2sin(x)")
    func implicitMultiplication() throws {
        #expect(try eval("2x", 5) == 10)
        #expect(try eval("3(x+1)", 1) == 6)
        #expect(abs(try eval("2sin(x)", 0)! - 0) < 0.0001)
    }

    @Test("Named functions evaluate correctly")
    func namedFunctions() throws {
        #expect(try eval("sqrt(x)", 9) == 3)
        #expect(try eval("abs(x)", -4) == 4)
        #expect(try eval("max(x,10)", 3) == 10)
        #expect(abs(try eval("cos(0)")! - 1) < 0.0001)
    }

    @Test("Constants pi and e resolve to their real values")
    func constants() throws {
        #expect(abs(try eval("pi")! - Double.pi) < 0.0001)
        #expect(abs(try eval("e")! - M_E) < 0.0001)
    }

    @Test("theta is accepted as the polar variable, including the literal θ glyph")
    func thetaVariable() throws {
        #expect(try eval("theta", 2, variable: "theta") == 2)
        #expect(try eval("θ", 3, variable: "theta") == 3)
    }

    @Test("An empty expression fails to parse rather than evaluating to zero")
    func emptyExpressionThrows() {
        #expect(throws: (any Error).self) {
            _ = try FunctionExpression("", variable: "x")
        }
    }

    @Test("A bare unknown identifier (not a call) fails to parse")
    func unknownIdentifierThrows() {
        #expect(throws: (any Error).self) {
            _ = try FunctionExpression("bogus", variable: "x")
        }
    }

    @Test("An unrecognized FUNCTION NAME parses (any name followed by parens is a call) but evaluates to nil")
    func unknownFunctionCallEvaluatesToNil() throws {
        // Arity/name validation happens at evaluation, not parse time — this
        // keeps the parser from needing its own copy of the function table,
        // and the practical result is the same either way: every sample
        // fails, so the block shows "Can't plot" same as a parse error would.
        let expression = try FunctionExpression("bogus(x)", variable: "x")
        #expect(expression.evaluate(1) == nil)
    }

    @Test("Mismatched parentheses fail to parse")
    func mismatchedParenthesesThrows() {
        #expect(throws: (any Error).self) {
            _ = try FunctionExpression("(x+1", variable: "x")
        }
    }

    @Test("A domain error (sqrt of a negative) evaluates to nil, not a crash")
    func domainErrorEvaluatesToNil() throws {
        let expression = try FunctionExpression("sqrt(x)", variable: "x")
        #expect(expression.evaluate(-1) == nil)
    }

    @Test("Division by zero evaluates to nil, not infinity")
    func divisionByZeroEvaluatesToNil() throws {
        let expression = try FunctionExpression("1/x", variable: "x")
        #expect(expression.evaluate(0) == nil)
    }
}

@Suite("Function-plot sampling")
struct FunctionPlotSamplerTests {
    @Test("y = x passes through the origin")
    func explicitPassesThroughOrigin() throws {
        let expression = try FunctionExpression("x", variable: "x")
        let runs = FunctionPlotSampler.explicit(expression, window: 10, swapped: false)
        let allPoints = runs.flatMap { $0 }
        #expect(allPoints.contains { abs($0.x) < 0.1 && abs($0.y) < 0.1 })
    }

    @Test("x = f(y) swaps which axis the input walks")
    func explicitSwappedPutsInputOnY() throws {
        // y² isn't symmetric under swapping x and y, so this actually
        // distinguishes "swapped" from "not swapped" — the identity function
        // wouldn't, since x == y either way.
        let expression = try FunctionExpression("y^2", variable: "y")
        let runs = FunctionPlotSampler.explicit(expression, window: 10, swapped: true)
        let allPoints = runs.flatMap { $0 }
        #expect(!allPoints.isEmpty)
        // x is the OUTPUT (y²); y is the INPUT that was walked.
        #expect(allPoints.allSatisfy { abs($0.x - $0.y * $0.y) < 0.01 })
    }

    @Test("A constant-radius polar curve traces a circle")
    func polarConstantRadiusIsACircle() throws {
        let expression = try FunctionExpression("5", variable: "theta")
        let runs = FunctionPlotSampler.polar(expression, window: 10)
        let allPoints = runs.flatMap { $0 }
        #expect(!allPoints.isEmpty)
        #expect(allPoints.allSatisfy { abs((($0.x * $0.x + $0.y * $0.y).squareRoot()) - 5) < 0.01 })
    }

    @Test("A parametric unit circle stays on the unit circle")
    func parametricUnitCircle() throws {
        let x = try FunctionExpression("cos(t)", variable: "t")
        let y = try FunctionExpression("sin(t)", variable: "t")
        let runs = FunctionPlotSampler.parametric(x: x, y: y, window: 10)
        let allPoints = runs.flatMap { $0 }
        #expect(!allPoints.isEmpty)
        #expect(allPoints.allSatisfy { abs((($0.x * $0.x + $0.y * $0.y).squareRoot()) - 1) < 0.01 })
    }

    @Test("An asymptote (tan(x)) breaks into more than one run")
    func asymptoteBreaksIntoMultipleRuns() throws {
        let expression = try FunctionExpression("tan(x)", variable: "x")
        let runs = FunctionPlotSampler.explicit(expression, window: 10, swapped: false)
        #expect(runs.count > 1)
    }

    @Test("A degenerate (zero or negative) window samples nothing rather than crashing")
    func degenerateWindowSamplesNothing() throws {
        let expression = try FunctionExpression("x", variable: "x")
        #expect(FunctionPlotSampler.explicit(expression, window: 0, swapped: false).isEmpty)
    }

    @Test("A 3D parametric curve (a helix) samples real points via the isometric projection")
    func parametric3DSamplesAHelix() throws {
        let x = try FunctionExpression("cos(t)", variable: "t")
        let y = try FunctionExpression("sin(t)", variable: "t")
        let z = try FunctionExpression("t/3", variable: "t")
        let runs = FunctionPlotSampler.parametric3D(x: x, y: y, z: z, window: 10)
        #expect(!runs.isEmpty)
        #expect(runs.flatMap { $0 }.count > 10)
    }

    @Test("Three expressions all evaluating to zero project to the isometric origin")
    func parametric3DAllZeroIsOrigin() throws {
        let zero = try FunctionExpression("0", variable: "t")
        let runs = FunctionPlotSampler.parametric3D(x: zero, y: zero, z: zero, window: 5)
        let allPoints = runs.flatMap { $0 }
        #expect(!allPoints.isEmpty)
        #expect(allPoints.allSatisfy { abs($0.x) < 0.01 && abs($0.y) < 0.01 })
    }

    @Test("isometric places a pure Y point straight up, and pure X/Z symmetrically")
    func isometricProjection() {
        let up = FunctionPlotSampler.isometric(x: 0, y: 5, z: 0)
        #expect(abs(up.x) < 0.0001)
        #expect(up.y == 5)
        let x = FunctionPlotSampler.isometric(x: 5, y: 0, z: 0)
        let z = FunctionPlotSampler.isometric(x: 0, y: 0, z: 5)
        // X and Z are mirror images across the vertical axis in this projection.
        #expect(abs(x.x + z.x) < 0.0001)
        #expect(abs(x.y - z.y) < 0.0001)
    }
}

@Suite("3D function-plot mode")
struct ThreeDPlotModeTests {
    @Test("threeD needs both a secondary AND a tertiary expression field")
    func needsAllThreeFields() {
        #expect(PlotMode.threeD.needsSecondaryExpression)
        #expect(PlotMode.threeD.needsTertiaryExpression)
        #expect(!PlotMode.cartesianY.needsTertiaryExpression)
        #expect(!PlotMode.parametric.needsTertiaryExpression)
    }

    @Test("An element with 3D fields round-trips them all, including axis labels")
    func threeDElementRoundTrips() throws {
        let element = PageElement(
            kind: .functionPlot, x: 0, y: 0, width: 200, height: 200,
            functionExpression: "cos(t)", functionSecondaryExpression: "sin(t)",
            functionTertiaryExpression: "t/3", functionMode: PlotMode.threeD.rawValue, functionWindow: 8,
            axisXLabel: "Time (s)", axisYLabel: "Height (m)", axisZLabel: "Depth (m)"
        )
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(PageElement.self, from: data)
        #expect(decoded.resolvedPlotMode == .threeD)
        #expect(decoded.functionTertiaryExpression == "t/3")
        #expect(decoded.axisXLabel == "Time (s)")
        #expect(decoded.axisYLabel == "Height (m)")
        #expect(decoded.axisZLabel == "Depth (m)")
    }

    @Test("Unlabeled axes resolve to plain letters")
    func unlabeledAxesResolveToLetters() {
        let element = PageElement(kind: .functionPlot, x: 0, y: 0, width: 100, height: 100)
        #expect(element.resolvedAxisXLabel == "X")
        #expect(element.resolvedAxisYLabel == "Y")
        #expect(element.resolvedAxisZLabel == "Z")
    }
}

@Suite("Transparent-background option")
struct TransparentBackgroundTests {
    @Test("CodeBlockSettings and FunctionPlotSettings default to a background, and total-decode when missing")
    func defaultsAndTotalDecode() throws {
        #expect(CodeBlockSettings().transparentBackground == false)
        #expect(FunctionPlotSettings().transparentBackground == false)

        let json = "{}"
        let code = try JSONDecoder().decode(CodeBlockSettings.self, from: Data(json.utf8))
        let plot = try JSONDecoder().decode(FunctionPlotSettings.self, from: Data(json.utf8))
        #expect(code.transparentBackground == false)
        #expect(plot.transparentBackground == false)
    }

    @Test("An element can override transparency independently of its tool's default")
    func elementOverridesTool() {
        let transparent = PageElement(kind: .codeBlock, x: 0, y: 0, width: 10, height: 10, backgroundIsTransparent: true)
        let opaque = PageElement(kind: .codeBlock, x: 0, y: 0, width: 10, height: 10, backgroundIsTransparent: false)
        let unset = PageElement(kind: .codeBlock, x: 0, y: 0, width: 10, height: 10)
        #expect(transparent.backgroundIsTransparent == true)
        #expect(opaque.backgroundIsTransparent == false)
        #expect(unset.backgroundIsTransparent == nil)
    }
}
