import ClassMateTheme
import NotesModels
import Observation
import PencilKit
import UIKit

/// The editor's tool selection + per-tool options, mapped to PencilKit tools.
///
/// The rail has two halves. The top half switches *mode* (write / tape / text /
/// move) and fires actions; the bottom half is the pen tray — every instrument in
/// `PenLibrary`, the eraser and the ruler — where the selected one lifts out of
/// the rail and tapping it again opens its settings.
///
/// Default ink colors come from the active theme.
@MainActor
@Observable
public final class ToolState {
    /// Canvas-affecting modes. Rail actions (insert, record, page settings, page
    /// manager, NOVA) are NOT tools — they live alongside these.
    public enum Tool: String, CaseIterable, Sendable, Identifiable {
        /// Writing with the selected pen from the tray.
        case pen
        case eraser
        /// Laying down sticky tape that masks what's underneath.
        case tape
        /// Tapping the page drops a typed text box.
        case text
        /// Moving / resizing the things already on the page; the pencil doesn't draw.
        case hand
        /// Tapping inside a shape floods it with the current colour.
        case fill
        /// Circling something selects it, for copying, moving or deleting.
        case lasso

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .pen: "Pen"
            case .eraser: "Eraser"
            case .tape: "Tape"
            case .text: "Text"
            case .hand: "Move"
            case .fill: "Fill"
            case .lasso: "Select"
            }
        }

        public var symbolName: String {
            switch self {
            case .pen: "pencil.tip"
            case .eraser: "eraser"
            case .tape: "square.on.square.dashed"
            case .text: "textformat"
            case .hand: "hand.point.up.left"
            case .fill: "drop.fill"
            case .lasso: "lasso"
            }
        }
    }

    /// Eraser precision: pixel (accurate, adjustable size) or whole-stroke, plus
    /// tape-only so a strip can be removed without touching the ink under it.
    public enum EraserMode: String, CaseIterable, Sendable, Identifiable {
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

    // MARK: - Mode

    public var tool: Tool = .pen
    /// Last writing tool, for Pencil double-tap toggling.
    public private(set) var previousDrawingTool: Tool = .pen

    // MARK: - Pen tray

    /// The instrument currently in hand.
    public var penPresetID: String = PenLibrary.default.id
    /// Per-instrument tuning, so switching pens keeps each one's own settings.
    private var tuning: [String: PenSettings] = [:]

    public var pen: PenPreset { PenLibrary.preset(id: penPresetID) }

    public func settings(for preset: PenPreset) -> PenSettings {
        (tuning[preset.id] ?? preset.defaults).normalized(in: preset.widthRange)
    }

    public var penSettings: PenSettings {
        get { settings(for: pen) }
        set { tuning[pen.id] = newValue.normalized(in: pen.widthRange) }
    }

    /// Stores one instrument's tuning. Panels edit whichever pen they were opened
    /// for, which is normally — but not necessarily — the one in hand.
    public func setSettings(_ settings: PenSettings, for preset: PenPreset) {
        tuning[preset.id] = settings.normalized(in: preset.widthRange)
    }

    /// Restores one instrument to its catalog defaults ("Reset" in its panel).
    public func resetPen(_ preset: PenPreset) {
        tuning[preset.id] = preset.defaults
    }

    /// Selects a tray instrument. Returns `true` when it was ALREADY selected —
    /// the rail uses that to open the instrument's settings on the second tap.
    @discardableResult
    public func selectPen(_ preset: PenPreset) -> Bool {
        let wasCurrent = tool == .pen && penPresetID == preset.id
        penPresetID = preset.id
        select(.pen)
        return wasCurrent
    }

    // MARK: - Tape

    public var tapeShape: TapeShape = .draw
    public var tapePattern: TapePattern = .stripes
    public var tapeThickness: Double = TapeGeometry.defaultThickness
    /// `nil` = follow the theme accent.
    public var tapeColorHex: String?

    public func tapeColor(theme: ThemeSpec) -> ThemeColor {
        tapeColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accentMuted
    }

    // MARK: - Eraser

    public var eraserMode: EraserMode = .pixel
    public var eraserWidth: Double = 20
    /// Scribble to erase: a quick back-and-forth scrub removes what it crosses
    /// instead of leaving a stroke. Works with any pen selected.
    public var scribbleToErase: Bool = false
    /// Hold at the end of a stroke to straighten it into a clean shape.
    public var snapShapes: Bool = true

    // MARK: - Text boxes

    public var textFontID: String = FontLibrary.default.id
    public var textSize: Double = 20
    public var textColorHex: String?

    // MARK: - Real-time beautification

    public var beautify = BeautifySettings()

    // MARK: - Focus mode

    /// Reading / highlighting mode: everything except the page you're on goes away
    /// — rail, bubble, navigation bar, the other pages — leaving the paper and an
    /// Exit button. Picking the highlighter up turns it on, because that's the tool
    /// you reach for when you're reading rather than writing.
    public var focusMode = false

    public init() {}

    /// The pen draws unless we're moving things, laying tape, or placing text —
    /// those modes own the pencil themselves.
    public var isDrawingEnabled: Bool { tool == .pen || tool == .eraser }

    public func select(_ newTool: Tool) {
        if tool == .pen || tool == .eraser {
            previousDrawingTool = tool
        }
        tool = newTool
    }

    /// Apple Pencil double-tap: honor the system preference where it maps to
    /// tool switching; anything else falls back to eraser toggle.
    public func handlePencilTap(preferred: UIPencilPreferredAction) {
        switch preferred {
        case .switchPrevious:
            let target = previousDrawingTool == tool ? Tool.pen : previousDrawingTool
            previousDrawingTool = tool
            tool = target
        default:
            toggleEraser()
        }
    }

    /// Apple Pencil squeeze: cycle pen → eraser → tape → hand.
    public func handlePencilSqueeze() {
        let order: [Tool] = [.pen, .eraser, .tape, .hand]
        guard let index = order.firstIndex(of: tool) else {
            select(.pen)
            return
        }
        select(order[(index + 1) % order.count])
    }

    private func toggleEraser() {
        if tool == .eraser {
            tool = previousDrawingTool == .eraser ? .pen : previousDrawingTool
        } else {
            select(.eraser)
        }
    }

    // MARK: - Colors

    /// Swatches offered for ink: the theme's ink + accent, then its cover palette.
    public func inkPalette(theme: ThemeSpec) -> [ThemeColor] {
        var seen = Set<String>()
        var palette: [ThemeColor] = []
        for candidate in [theme.ink, theme.accent] + theme.coverPalette {
            if seen.insert(candidate.hexString).inserted {
                palette.append(candidate)
            }
            if palette.count == 10 { break }
        }
        return palette
    }

    public func currentColor(theme: ThemeSpec) -> ThemeColor {
        penSettings.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink
    }

    public func setCurrentColor(_ color: ThemeColor) {
        var updated = penSettings
        updated.colorHex = color.hexString
        penSettings = updated
    }

    /// The nominal thickness of the instrument in hand.
    public var currentWidth: Double {
        get { penSettings.thickness }
        set {
            var updated = penSettings
            updated.thickness = newValue
            penSettings = updated
        }
    }

    // MARK: - PencilKit mapping

    public func pkTool(theme: ThemeSpec) -> PKTool {
        switch tool {
        case .pen:
            let preset = pen
            let settings = settings(for: preset)
            let base = settings.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink
            let color = base.uiColor.withAlphaComponent(settings.concentration)
            return PKInkingTool(preset.ink.pkInkType, color: color, width: settings.effectiveWidth)
        case .eraser:
            switch eraserMode {
            case .pixel: return PKEraserTool(.bitmap, width: eraserWidth)
            case .stroke: return PKEraserTool(.vector)
            // Tape lives above the ink as page elements, so the canvas itself must
            // not erase anything in this mode — the tape layer handles the taps.
            case .tapeOnly: return PKInkingTool(.pen, color: .clear, width: 1)
            }
        case .tape, .text, .hand, .fill, .lasso:
            // Inert — drawing is disabled in these modes; the value is unused.
            return PKInkingTool(.pen, color: .clear, width: 1)
        }
    }
}

extension PenPreset.Ink {
    /// The PencilKit ink family behind this pen. Kept here so the model layer
    /// stays free of PencilKit.
    public var pkInkType: PKInk.InkType {
        switch self {
        case .pen: .pen
        case .pencil: .pencil
        case .marker: .marker
        case .fountainPen: .fountainPen
        case .monoline: .monoline
        case .watercolor: .watercolor
        case .crayon: .crayon
        }
    }
}

extension ThemeColor {
    /// UIKit bridge for PencilKit tools.
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
