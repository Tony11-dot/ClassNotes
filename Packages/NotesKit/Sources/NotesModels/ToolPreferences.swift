import Foundation

/// Eraser precision: pixel (accurate, adjustable size) or whole-stroke, plus
/// tape-only so a strip can be removed without touching the ink under it.
///
/// Lives here rather than on `ToolState` because it is part of what gets saved
/// and carried between devices, and the iPhone — which never imports the editor
/// — still has to be able to decode it.
public enum EraserMode: String, CaseIterable, Sendable, Codable, Identifiable {
    case pixel
    case stroke
    case tapeOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pixel: "Pixel"
        case .stroke: "Stroke"
        case .tapeOnly: "Tape only"
        }
    }
}

/// What a Pencil gesture does. The hardware offers two — a double tap on the
/// barrel and a squeeze — and the user picks what each one means, because which
/// two tools you swap between is personal: the answer for someone annotating a
/// PDF is not the answer for someone drawing diagrams.
public enum PencilAction: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Swap to the eraser and back to whatever was in hand.
    case toggleEraser
    /// Back to the previous writing tool.
    case previousTool
    /// Step through the pen tray.
    case cyclePens
    /// Step through pen → eraser → tape → move.
    case cycleTools
    /// Open the colour swatches for the instrument in hand.
    case showColors
    /// The lasso, for grabbing part of the page.
    case selectTool
    /// The ruler, on and off.
    case toggleRuler
    /// Undo the last thing.
    case undo
    /// Ask NOVA about the page.
    case askNova
    /// Nothing at all.
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .toggleEraser: "Switch to eraser"
        case .previousTool: "Previous tool"
        case .cyclePens: "Cycle pens"
        case .cycleTools: "Cycle tools"
        case .showColors: "Show colours"
        case .selectTool: "Select (lasso)"
        case .toggleRuler: "Show ruler"
        case .undo: "Undo"
        case .askNova: "Ask NOVA"
        case .none: "Do nothing"
        }
    }

    public var symbolName: String {
        switch self {
        case .toggleEraser: "eraser"
        case .previousTool: "arrow.left.arrow.right"
        case .cyclePens: "pencil.tip.crop.circle"
        case .cycleTools: "square.grid.2x2"
        case .showColors: "paintpalette"
        case .selectTool: "lasso"
        case .toggleRuler: "ruler"
        case .undo: "arrow.uturn.backward"
        case .askNova: "sparkles"
        case .none: "nosign"
        }
    }
}

/// How a code block is typeset — the panel behind its own style button. Every
/// code block starts from these defaults and can be overridden per-element
/// (`PageElement.fontName`/`fontSize`/`textColorHex`/`colorHex`/`codeCornerRadius`).
public struct CodeBlockSettings: Sendable, Equatable, Codable {
    /// `FontLibrary` catalog id — monospace faces only.
    public var fontID: String
    public var fontSize: Double
    /// `nil` = `Self.defaultTextHex`.
    public var textColorHex: String?
    /// `nil` = `Self.defaultBackgroundHex`.
    public var backgroundColorHex: String?
    public var cornerRadius: Double
    /// Which language new code blocks are labelled — and coloured — as.
    public var language: CodeLanguage
    /// No background box/frame at all — just the bare syntax text on the page.
    public var transparentBackground: Bool

    public init(
        fontID: String = "menlo",
        fontSize: Double = 15,
        textColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        cornerRadius: Double = 10,
        language: CodeLanguage = .swift,
        transparentBackground: Bool = false
    ) {
        self.fontID = fontID
        self.fontSize = fontSize
        self.textColorHex = textColorHex
        self.backgroundColorHex = backgroundColorHex
        self.cornerRadius = cornerRadius
        self.language = language
        self.transparentBackground = transparentBackground
    }

    private enum CodingKeys: String, CodingKey {
        case fontID, fontSize, textColorHex, backgroundColorHex, cornerRadius, language
        case transparentBackground
    }

    /// Total decode: an older/corrupt blob without `language` still loads,
    /// defaulting to Swift rather than losing the rest of the settings.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fontID: (try? box.decodeIfPresent(String.self, forKey: .fontID)) ?? nil ?? "menlo",
            fontSize: (try? box.decodeIfPresent(Double.self, forKey: .fontSize)) ?? nil ?? 15,
            textColorHex: (try? box.decodeIfPresent(String.self, forKey: .textColorHex)) ?? nil,
            backgroundColorHex: (try? box.decodeIfPresent(String.self, forKey: .backgroundColorHex)) ?? nil,
            cornerRadius: (try? box.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? nil ?? 10,
            language: (try? box.decodeIfPresent(CodeLanguage.self, forKey: .language)) ?? nil ?? .swift,
            transparentBackground: (try? box.decodeIfPresent(Bool.self, forKey: .transparentBackground)) ?? nil ?? false
        )
    }

    public static let fontSizeRange: ClosedRange<Double> = 10...28
    public static let cornerRadiusRange: ClosedRange<Double> = 0...24
    /// A dark "console" look by default — the same idea every AI assistant's
    /// code block reaches for, so it reads as code rather than as a text box.
    public static let defaultBackgroundHex = "#1E1E2E"
    public static let defaultTextHex = "#CDD6F4"
}

/// Styling and defaults for function-plot blocks — mirrors `CodeBlockSettings`.
public struct FunctionPlotSettings: Sendable, Equatable, Codable {
    public var mode: PlotMode
    /// `nil` = `Self.defaultLineHex`.
    public var lineColorHex: String?
    /// `nil` = `Self.defaultBackgroundHex`.
    public var backgroundColorHex: String?
    public var cornerRadius: Double
    /// Half-width of the default view window, in math units (so the default
    /// window is roughly `-window...window` on the relevant axis/parameter).
    public var window: Double
    /// No background box/frame at all — just the bare axes and curve on the page.
    public var transparentBackground: Bool

    public init(
        mode: PlotMode = .cartesianY,
        lineColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        cornerRadius: Double = 10,
        window: Double = 10,
        transparentBackground: Bool = false
    ) {
        self.mode = mode
        self.lineColorHex = lineColorHex
        self.backgroundColorHex = backgroundColorHex
        self.cornerRadius = cornerRadius
        self.window = window
        self.transparentBackground = transparentBackground
    }

    private enum CodingKeys: String, CodingKey {
        case mode, lineColorHex, backgroundColorHex, cornerRadius, window
        case transparentBackground
    }

    /// Total decode: an older/corrupt blob still loads, defaulting whatever
    /// it's missing rather than losing the rest of the settings.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: (try? box.decodeIfPresent(PlotMode.self, forKey: .mode)) ?? nil ?? .cartesianY,
            lineColorHex: (try? box.decodeIfPresent(String.self, forKey: .lineColorHex)) ?? nil,
            backgroundColorHex: (try? box.decodeIfPresent(String.self, forKey: .backgroundColorHex)) ?? nil,
            cornerRadius: (try? box.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? nil ?? 10,
            window: (try? box.decodeIfPresent(Double.self, forKey: .window)) ?? nil ?? 10,
            transparentBackground: (try? box.decodeIfPresent(Bool.self, forKey: .transparentBackground)) ?? nil ?? false
        )
    }

    public static let cornerRadiusRange: ClosedRange<Double> = 0...24
    public static let windowRange: ClosedRange<Double> = 2...100
    public static let defaultBackgroundHex = "#1E1E2E"
    public static let defaultLineHex = "#89B4FA"
}

/// Everything the editor's tools remember: which instrument is in hand, how each
/// one is tuned, the eraser, tape, text boxes, beautification, and what the
/// Pencil's gestures do.
///
/// This is a plain `Codable` value, deliberately: it is saved to SwiftData, it is
/// what travels between a user's iPad and their iPhone, and none of that can
/// depend on PencilKit or on the editor module, which the iPhone never builds.
///
/// Decoding is TOTAL — every field has a default, so a blob written by a newer
/// version (or a corrupt one) loads with the fields it does understand rather
/// than throwing away the user's whole setup.
public struct ToolPreferences: Codable, Sendable, Equatable {
    // Pens
    public var penPresetID: String
    /// Per-instrument tuning, keyed by preset id, so switching pens keeps each
    /// one's own thickness, colour and feel.
    public var tuning: [String: PenSettings]

    // Tape
    public var tapeShape: TapeShape
    public var tapePattern: TapePattern
    public var tapeThickness: Double
    /// `nil` = follow the theme accent.
    public var tapeColorHex: String?

    // Eraser and stroke handling
    public var eraserMode: EraserMode
    public var eraserWidth: Double
    public var scribbleToErase: Bool
    public var snapShapes: Bool
    /// How far the pencil may drift during the end-of-stroke hold and still count
    /// as resting, in screen points — the tolerance behind "hold to snap". Wider
    /// forgives more hand tremor; narrower asks for a steadier hold.
    public var snapTolerance: Double

    // Text boxes
    public var textFontID: String
    public var textSize: Double
    public var textColorHex: String?

    // Code blocks
    public var codeBlock: CodeBlockSettings

    // Function-plot blocks
    public var functionPlot: FunctionPlotSettings

    // Beautification
    public var beautify: BeautifySettings

    // Pencil gestures
    public var pencilDoubleTap: PencilAction
    public var pencilSqueeze: PencilAction

    public init(
        penPresetID: String = PenLibrary.default.id,
        tuning: [String: PenSettings] = [:],
        tapeShape: TapeShape = .draw,
        tapePattern: TapePattern = .stripes,
        tapeThickness: Double = TapeGeometry.defaultThickness,
        tapeColorHex: String? = nil,
        eraserMode: EraserMode = .pixel,
        eraserWidth: Double = 20,
        scribbleToErase: Bool = false,
        snapShapes: Bool = true,
        snapTolerance: Double = 22,
        textFontID: String = FontLibrary.default.id,
        textSize: Double = 20,
        textColorHex: String? = nil,
        codeBlock: CodeBlockSettings = CodeBlockSettings(),
        functionPlot: FunctionPlotSettings = FunctionPlotSettings(),
        beautify: BeautifySettings = BeautifySettings(),
        pencilDoubleTap: PencilAction = .toggleEraser,
        pencilSqueeze: PencilAction = .showColors
    ) {
        self.penPresetID = penPresetID
        self.tuning = tuning
        self.tapeShape = tapeShape
        self.tapePattern = tapePattern
        self.tapeThickness = tapeThickness
        self.tapeColorHex = tapeColorHex
        self.eraserMode = eraserMode
        self.eraserWidth = eraserWidth
        self.scribbleToErase = scribbleToErase
        self.snapShapes = snapShapes
        self.snapTolerance = snapTolerance
        self.textFontID = textFontID
        self.textSize = textSize
        self.textColorHex = textColorHex
        self.codeBlock = codeBlock
        self.functionPlot = functionPlot
        self.beautify = beautify
        self.pencilDoubleTap = pencilDoubleTap
        self.pencilSqueeze = pencilSqueeze
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ToolPreferences()
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? box.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? `default`
        }
        self.init(
            penPresetID: value(.penPresetID, fallback.penPresetID),
            tuning: value(.tuning, fallback.tuning),
            tapeShape: value(.tapeShape, fallback.tapeShape),
            tapePattern: value(.tapePattern, fallback.tapePattern),
            tapeThickness: value(.tapeThickness, fallback.tapeThickness),
            tapeColorHex: (try? box.decodeIfPresent(String.self, forKey: .tapeColorHex)) ?? nil,
            eraserMode: value(.eraserMode, fallback.eraserMode),
            eraserWidth: value(.eraserWidth, fallback.eraserWidth),
            scribbleToErase: value(.scribbleToErase, fallback.scribbleToErase),
            snapShapes: value(.snapShapes, fallback.snapShapes),
            snapTolerance: value(.snapTolerance, fallback.snapTolerance),
            textFontID: value(.textFontID, fallback.textFontID),
            textSize: value(.textSize, fallback.textSize),
            textColorHex: (try? box.decodeIfPresent(String.self, forKey: .textColorHex)) ?? nil,
            codeBlock: value(.codeBlock, fallback.codeBlock),
            functionPlot: value(.functionPlot, fallback.functionPlot),
            beautify: value(.beautify, fallback.beautify),
            pencilDoubleTap: value(.pencilDoubleTap, fallback.pencilDoubleTap),
            pencilSqueeze: value(.pencilSqueeze, fallback.pencilSqueeze)
        )
    }

    public static let snapToleranceRange: ClosedRange<Double> = 10...40
}

/// The whole of "how this user has their app set up", as one value: the tools,
/// the theme, the paper tone. This is the unit that travels between a person's
/// own devices, so that signing in on a second device gives them the app they
/// already configured rather than a factory-fresh one.
public struct DeviceSettings: Codable, Sendable, Equatable {
    /// Bumped every time anything here changes; the newer revision wins when two
    /// devices have both been edited. A wall clock alone can't arbitrate that —
    /// devices disagree about the time, and a phone an hour behind would quietly
    /// undo the iPad's settings every launch.
    public var revision: Int
    public var updatedAt: Date
    public var tools: ToolPreferences
    /// `ThemeSelection.rawValue` — a preset id, "system", or a custom theme's id.
    public var themeSelection: String
    public var paperTone: String

    public init(
        revision: Int = 0,
        updatedAt: Date = .now,
        tools: ToolPreferences = ToolPreferences(),
        themeSelection: String = "system",
        paperTone: String = "neutral"
    ) {
        self.revision = revision
        self.updatedAt = updatedAt
        self.tools = tools
        self.themeSelection = themeSelection
        self.paperTone = paperTone
    }

    /// Which of two copies to keep. Higher revision wins; a tie is broken by the
    /// timestamp, and a tie there keeps `self` so the decision is stable.
    public static func newer(_ lhs: DeviceSettings, _ rhs: DeviceSettings) -> DeviceSettings {
        if lhs.revision != rhs.revision { return lhs.revision > rhs.revision ? lhs : rhs }
        return rhs.updatedAt > lhs.updatedAt ? rhs : lhs
    }
}
