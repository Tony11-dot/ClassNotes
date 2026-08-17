import ClassMateTheme
import NotesModels
import NotesServices
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
        /// Tapping the page drops a typeset, styled block of source code.
        case codeBlock
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
            case .codeBlock: "Code"
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
            case .codeBlock: "chevron.left.forwardslash.chevron.right"
            case .hand: "hand.point.up.left"
            case .fill: "drop.fill"
            case .lasso: "lasso"
            }
        }
    }

    /// Eraser precision. The type itself lives in `NotesModels` now, because it
    /// is part of what gets saved and carried between devices — but it is still
    /// spelled `ToolState.EraserMode` everywhere it is used.
    public typealias EraserMode = NotesModels.EraserMode

    // MARK: - Where the settings actually live

    /// The durable copy. Everything below that a user can tune is a live view of
    /// it, so moving a slider is saved and carried to their other devices — it
    /// used to live in this object alone, which meant every adjustment was
    /// forgotten the moment the editor closed.
    ///
    /// Optional so previews and tests can drive a `ToolState` without a store,
    /// and bound after init because the editor only meets `AppServices` through
    /// the environment. Ignored by observation on purpose — what views need to
    /// watch is the store's own `tools`, which it publishes itself.
    @ObservationIgnored private var store: SettingsStore?
    /// Stands in for the store when there isn't one.
    private var detached = ToolPreferences()

    /// Points this state at the saved settings. Anything tuned before the store
    /// arrived comes along, so a change made on the very first frame isn't lost.
    public func bind(to store: SettingsStore) {
        guard self.store == nil else { return }
        self.store = store
        let pending = detached
        if pending != ToolPreferences() {
            store.update { $0 = pending }
        }
    }

    public var preferences: ToolPreferences { store?.tools ?? detached }

    func edit(_ mutate: (inout ToolPreferences) -> Void) {
        if let store {
            store.update(mutate)
        } else {
            mutate(&detached)
        }
    }

    // MARK: - Mode

    public var tool: Tool = .pen
    /// Last writing tool, for Pencil double-tap toggling.
    public private(set) var previousDrawingTool: Tool = .pen

    // MARK: - Pen tray

    /// The instrument currently in hand.
    public var penPresetID: String {
        get { preferences.penPresetID }
        set { edit { $0.penPresetID = newValue } }
    }

    public var pen: PenPreset { PenLibrary.preset(id: penPresetID) }

    public func settings(for preset: PenPreset) -> PenSettings {
        (preferences.tuning[preset.id] ?? preset.defaults).normalized(in: preset.widthRange)
    }

    public var penSettings: PenSettings {
        get { settings(for: pen) }
        set { setSettings(newValue, for: pen) }
    }

    /// Stores one instrument's tuning. Panels edit whichever pen they were opened
    /// for, which is normally — but not necessarily — the one in hand.
    public func setSettings(_ settings: PenSettings, for preset: PenPreset) {
        let normalized = settings.normalized(in: preset.widthRange)
        edit { $0.tuning[preset.id] = normalized }
    }

    /// Restores one instrument to its catalog defaults ("Reset" in its panel).
    public func resetPen(_ preset: PenPreset) {
        let defaults = preset.defaults
        edit { $0.tuning[preset.id] = defaults }
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

    public var tapeShape: TapeShape {
        get { preferences.tapeShape }
        set { edit { $0.tapeShape = newValue } }
    }

    public var tapePattern: TapePattern {
        get { preferences.tapePattern }
        set { edit { $0.tapePattern = newValue } }
    }

    public var tapeThickness: Double {
        get { preferences.tapeThickness }
        set { edit { $0.tapeThickness = newValue } }
    }

    /// `nil` = follow the theme accent.
    public var tapeColorHex: String? {
        get { preferences.tapeColorHex }
        set { edit { $0.tapeColorHex = newValue } }
    }

    public func tapeColor(theme: ThemeSpec) -> ThemeColor {
        tapeColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accentMuted
    }

    // MARK: - Eraser

    public var eraserMode: EraserMode {
        get { preferences.eraserMode }
        set { edit { $0.eraserMode = newValue } }
    }

    public var eraserWidth: Double {
        get { preferences.eraserWidth }
        set { edit { $0.eraserWidth = newValue } }
    }

    /// Scribble to erase: a quick back-and-forth scrub removes what it crosses
    /// instead of leaving a stroke. Works with any pen selected.
    public var scribbleToErase: Bool {
        get { preferences.scribbleToErase }
        set { edit { $0.scribbleToErase = newValue } }
    }

    /// Hold at the end of a stroke to straighten it into a clean shape.
    public var snapShapes: Bool {
        get { preferences.snapShapes }
        set { edit { $0.snapShapes = newValue } }
    }

    // MARK: - Text boxes

    public var textFontID: String {
        get { preferences.textFontID }
        set { edit { $0.textFontID = newValue } }
    }

    public var textSize: Double {
        get { preferences.textSize }
        set { edit { $0.textSize = newValue } }
    }

    public var textColorHex: String? {
        get { preferences.textColorHex }
        set { edit { $0.textColorHex = newValue } }
    }

    // MARK: - Code blocks

    public var codeBlockFontID: String {
        get { preferences.codeBlock.fontID }
        set { edit { $0.codeBlock.fontID = newValue } }
    }

    public var codeBlockFontSize: Double {
        get { preferences.codeBlock.fontSize }
        set { edit { $0.codeBlock.fontSize = newValue } }
    }

    public var codeBlockTextColorHex: String? {
        get { preferences.codeBlock.textColorHex }
        set { edit { $0.codeBlock.textColorHex = newValue } }
    }

    public var codeBlockBackgroundColorHex: String? {
        get { preferences.codeBlock.backgroundColorHex }
        set { edit { $0.codeBlock.backgroundColorHex = newValue } }
    }

    public var codeBlockCornerRadius: Double {
        get { preferences.codeBlock.cornerRadius }
        set { edit { $0.codeBlock.cornerRadius = newValue } }
    }

    // MARK: - Real-time beautification

    public var beautify: BeautifySettings {
        get { preferences.beautify }
        set { edit { $0.beautify = newValue } }
    }

    // MARK: - Focus mode

    /// Reading / highlighting mode: everything except the page you're on goes away
    /// — rail, bubble, navigation bar, the other pages — leaving the paper and an
    /// Exit button. Picking the highlighter up turns it on, because that's the tool
    /// you reach for when you're reading rather than writing.
    public var focusMode = false

    public init(store: SettingsStore? = nil) {
        self.store = store
    }

    /// The pen draws unless we're moving things, laying tape, or placing text —
    /// those modes own the pencil themselves.
    public var isDrawingEnabled: Bool { tool == .pen || tool == .eraser }

    public func select(_ newTool: Tool) {
        if tool == .pen || tool == .eraser {
            previousDrawingTool = tool
        }
        tool = newTool
    }

    // MARK: - Apple Pencil gestures

    /// What the editor has to do about a Pencil gesture that `ToolState` can't
    /// carry out on its own — the rail's undo stack, the ruler, NOVA, the colour
    /// swatches. Returned rather than fired through a delegate so the mapping
    /// stays a pure function of the settings and can be tested without a canvas.
    public enum PencilOutcome: Equatable, Sendable {
        case handled
        case showColors
        case toggleRuler
        case undo
        case askNova
    }

    /// Apple Pencil double-tap. What it does is the user's choice; the system's
    /// own preference is only consulted when they haven't expressed one.
    @discardableResult
    public func handlePencilTap() -> PencilOutcome {
        perform(preferences.pencilDoubleTap)
    }

    /// Apple Pencil squeeze — the second gesture, with its own mapping.
    @discardableResult
    public func handlePencilSqueeze() -> PencilOutcome {
        perform(preferences.pencilSqueeze)
    }

    @discardableResult
    public func perform(_ action: PencilAction) -> PencilOutcome {
        switch action {
        case .toggleEraser:
            toggleEraser()
        case .previousTool:
            let target = previousDrawingTool == tool ? Tool.pen : previousDrawingTool
            previousDrawingTool = tool
            tool = target
        case .cyclePens:
            cyclePens()
        case .cycleTools:
            let order: [Tool] = [.pen, .eraser, .tape, .hand]
            let index = order.firstIndex(of: tool)
            select(index.map { order[($0 + 1) % order.count] } ?? .pen)
        case .selectTool:
            select(tool == .lasso ? previousDrawingTool : .lasso)
        case .none:
            break
        case .showColors:
            return escalate(.showColors)
        case .toggleRuler:
            return escalate(.toggleRuler)
        case .undo:
            return escalate(.undo)
        case .askNova:
            return escalate(.askNova)
        }
        return .handled
    }

    /// Hands an outcome this object can't carry out to whoever owns the screen.
    /// Set by `EditorScreen`; nil everywhere else, so the mapping itself stays
    /// testable without a canvas.
    @ObservationIgnored
    public var onPencilOutcome: ((PencilOutcome) -> Void)?

    private func escalate(_ outcome: PencilOutcome) -> PencilOutcome {
        onPencilOutcome?(outcome)
        return outcome
    }

    /// Steps to the next instrument in the tray, picking the pen up if the user
    /// was holding something that isn't one.
    public func cyclePens() {
        let all = PenLibrary.all
        guard !all.isEmpty else { return }
        guard tool == .pen, let index = all.firstIndex(where: { $0.id == penPresetID }) else {
            selectPen(all[0])
            return
        }
        selectPen(all[(index + 1) % all.count])
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
        case .tape, .text, .codeBlock, .hand, .fill, .lasso:
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
