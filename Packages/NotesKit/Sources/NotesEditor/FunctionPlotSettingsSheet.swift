import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI

/// One axis's editable settings, bundled so the sheet doesn't carry four
/// separate `@State` vars per axis times three axes.
struct AxisFieldState {
    var name = ""
    var unit = ""
    var tickFormat: AxisTickFormat = .decimal
    var tickInterval: Double?

    init() {}

    init(label: String?, unit: String?, display: AxisDisplay) {
        self.name = label ?? ""
        self.unit = unit ?? ""
        self.tickFormat = display.tickFormat
        self.tickInterval = display.tickInterval
    }
}

/// Everything a function-plot commit needs, bundled so callers don't grow an
/// ever-longer tuple as the block gains fields. `public` because
/// `NotebookEditorModel.insertFunctionPlot(draft:)` — a public API, called
/// from `App/Routing` — takes one.
public struct FunctionPlotDraft {
    public var mode: PlotMode
    public var expression: String
    public var secondary: String?
    public var tertiary: String?
    public var window: Double
    public var axisXLabel: String?
    public var axisYLabel: String?
    public var axisZLabel: String?
    public var axisXUnit: String?
    public var axisYUnit: String?
    public var axisZUnit: String?
    public var axisXTickFormat: AxisTickFormat?
    public var axisYTickFormat: AxisTickFormat?
    public var axisZTickFormat: AxisTickFormat?
    public var axisXTickInterval: Double?
    public var axisYTickInterval: Double?
    public var axisZTickInterval: Double?
}

/// The ONE place a function plot's settings are edited — for a brand new
/// graph (with a "Create" button, placed only once every setting is chosen)
/// and for an existing one (a "Save" button, opened by holding it) alike.
///
/// A big `.sheet`, not a popover sized to whatever the block happens to be on
/// the page: the block might be a 200×200 thumbnail, and cramming an axis
/// picker, a curve-type picker, up to three expression fields, up to three
/// full axis-settings blocks, two colour rows and a zoom slider into that
/// footprint is exactly what made editing feel too compact to use. Sizing the
/// sheet to the SCREEN instead of the ELEMENT is the whole fix.
struct FunctionPlotSettingsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    let toolState: ToolState
    let onCommit: (
        FunctionPlotDraft, _ lineColorHex: String, _ backgroundColorHex: String,
        _ cornerRadius: Double, _ transparentBackground: Bool
    ) -> Void
    let onDelete: (() -> Void)?

    @State private var mode: PlotMode
    /// The last 2-axis curve type picked, so toggling the axis count away from
    /// 2 and back doesn't lose which of cartesianY/cartesianX/polar/parametric
    /// was selected.
    @State private var twoAxisMode: PlotMode
    @State private var draft: String
    @State private var secondaryDraft: String
    @State private var tertiaryDraft: String
    @State private var window: Double
    @State private var axisX: AxisFieldState
    @State private var axisY: AxisFieldState
    @State private var axisZ: AxisFieldState
    @State private var lineColorHex: String
    @State private var backgroundColorHex: String
    @State private var transparentBackground: Bool
    @State private var cornerRadius: Double
    @State private var confirmDelete = false
    @State private var showPresetPicker = false

    private enum Field: Hashable { case primary, secondary, tertiary }
    @FocusState private var focusedField: Field?

    private var axisCount: Int { mode.axisCount }

    init(
        isNew: Bool,
        toolState: ToolState,
        mode: PlotMode, expression: String, secondary: String?, tertiary: String?, window: Double,
        axisXLabel: String?, axisYLabel: String?, axisZLabel: String?,
        axisXUnit: String?, axisYUnit: String?, axisZUnit: String?,
        axisXDisplay: AxisDisplay, axisYDisplay: AxisDisplay, axisZDisplay: AxisDisplay,
        lineColorHex: String, backgroundColorHex: String, transparentBackground: Bool, cornerRadius: Double,
        onCommit: @escaping (
            FunctionPlotDraft, _ lineColorHex: String, _ backgroundColorHex: String,
            _ cornerRadius: Double, _ transparentBackground: Bool
        ) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.isNew = isNew
        self.toolState = toolState
        self.onCommit = onCommit
        self.onDelete = onDelete
        _mode = State(initialValue: mode)
        _twoAxisMode = State(initialValue: mode.axisCount == 2 ? mode : .cartesianY)
        _draft = State(initialValue: expression)
        _secondaryDraft = State(initialValue: secondary ?? "")
        _tertiaryDraft = State(initialValue: tertiary ?? "")
        _window = State(initialValue: window)
        _axisX = State(initialValue: AxisFieldState(label: axisXLabel, unit: axisXUnit, display: axisXDisplay))
        _axisY = State(initialValue: AxisFieldState(label: axisYLabel, unit: axisYUnit, display: axisYDisplay))
        _axisZ = State(initialValue: AxisFieldState(label: axisZLabel, unit: axisZUnit, display: axisZDisplay))
        _lineColorHex = State(initialValue: lineColorHex)
        _backgroundColorHex = State(initialValue: backgroundColorHex)
        _transparentBackground = State(initialValue: transparentBackground)
        _cornerRadius = State(initialValue: cornerRadius)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    preview
                    presetsSection
                    axesSection
                    expressionsSection
                    axisSettingsSection
                    appearanceSection
                    zoomSection
                    if !isNew, let onDelete {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete graph", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .confirmationDialog(
                            "Delete this graph?", isPresented: $confirmDelete, titleVisibility: .visible
                        ) {
                            Button("Delete", role: .destructive) { onDelete() }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                }
                .padding(24)
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle(isNew ? "New Graph" : "Edit Graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { commit() }
                        .font(.dsSubheadline.weight(.semibold))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    ForEach(Self.mathTokens, id: \.label) { token in
                        Button(token.label) { insert(token.insert) }
                            .font(.dsCaption.monospaced())
                    }
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .font(.dsSubheadline.weight(.semibold))
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showPresetPicker) {
            GraphPresetPickerSheet(recentIDs: toolState.recentGraphPresetIDs) { preset in
                apply(preset)
            }
        }
    }

    // MARK: - Sections

    /// A quick start into a graph someone already knows the shape of — e^x, a
    /// v-t line, O(n log n) — instead of typing every expression from scratch.
    private var presetsSection: some View {
        Button {
            showPresetPicker = true
        } label: {
            Label("Known Graphs", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    /// Drops a picked preset straight into the draft — same fields a "Create"
    /// press would commit — and records it as Recent so it comes back up top
    /// next time. Axis label/unit are only overwritten when the preset actually
    /// specifies one, so picking a plain math preset after typing a physics
    /// axis name doesn't clobber it with blanks.
    private func apply(_ preset: GraphPreset) {
        mode = preset.mode
        if preset.mode.axisCount == 2 { twoAxisMode = preset.mode }
        draft = preset.expression
        secondaryDraft = preset.secondaryExpression ?? ""
        window = preset.window
        if let label = preset.axisXLabel { axisX.name = label }
        if let unit = preset.axisXUnit { axisX.unit = unit }
        if let label = preset.axisYLabel { axisY.name = label }
        if let unit = preset.axisYUnit { axisY.unit = unit }
        toolState.recordRecentGraphPreset(preset.id)
    }

    private var preview: some View {
        FunctionPlotView(
            expression: draft, secondaryExpression: secondaryDraft, tertiaryExpression: tertiaryDraft,
            mode: mode, window: window,
            lineColor: ThemeColor(hex: lineColorHex)?.color ?? theme.accent.color,
            axisColor: ThemeColor(hex: lineColorHex)?.color ?? theme.accent.color,
            axisX: axisDisplay(axisX, fallback: "X"),
            axisY: axisDisplay(axisY, fallback: "Y"),
            axisZ: axisDisplay(axisZ, fallback: "Z")
        )
        .frame(height: 260)
        .padding(12)
        .background(
            transparentBackground ? Color.clear : (ThemeColor(hex: backgroundColorHex)?.color ?? theme.surfaceRaised.color),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            if !transparentBackground {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.separator.color, lineWidth: 0.5)
            }
        }
    }

    private var axesSection: some View {
        sectionBox(title: "Axes") {
            Picker("Axes", selection: axisCountBinding) {
                Text("1 axis").tag(1)
                Text("2 axes").tag(2)
                Text("3 axes").tag(3)
            }
            .pickerStyle(.segmented)
            if axisCount == 2 {
                Picker("Curve", selection: twoAxisModeBinding) {
                    ForEach([PlotMode.cartesianY, .cartesianX, .polar, .parametric]) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    @ViewBuilder
    private var expressionsSection: some View {
        if mode != .axis {
            sectionBox(title: "Function") {
                fieldRow(mode.needsSecondaryExpression ? "x(t) =" : "\(mode.variableLabel) =", text: $draft, field: .primary)
                if mode.needsSecondaryExpression {
                    fieldRow("y(t) =", text: $secondaryDraft, field: .secondary)
                }
                if mode.needsTertiaryExpression {
                    fieldRow("z(t) =", text: $tertiaryDraft, field: .tertiary)
                }
                Text("Use the keyboard row above the keyboard for √, ^, |x|, π, sin/cos/tan and more.")
                    .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
            }
        }
    }

    private var axisSettingsSection: some View {
        sectionBox(title: "Axis names, units & ticks") {
            VStack(alignment: .leading, spacing: 18) {
                axisSettingsRow(title: "X axis", state: $axisX, placeholder: "X")
                if axisCount >= 2 {
                    axisSettingsRow(title: "Y axis", state: $axisY, placeholder: "Y")
                }
                if axisCount == 3 {
                    axisSettingsRow(title: "Z axis", state: $axisZ, placeholder: "Z")
                }
            }
        }
    }

    private var appearanceSection: some View {
        sectionBox(title: "Appearance") {
            Text("Curve colour").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
            ColorSwatchRow(
                swatches: [FunctionPlotSettings.defaultLineHex] + theme.coverPalette.map(\.hexString),
                selection: Binding(get: { lineColorHex }, set: { lineColorHex = $0 ?? FunctionPlotSettings.defaultLineHex })
            )
            Text("Background").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
            ColorSwatchRow(
                swatches: [FunctionPlotSettings.defaultBackgroundHex] + theme.coverPalette.map(\.hexString),
                selection: Binding(get: { backgroundColorHex }, set: { backgroundColorHex = $0 ?? FunctionPlotSettings.defaultBackgroundHex })
            )
            PanelSlider(
                title: "Corner radius",
                readout: "\(Int(cornerRadius.rounded()))",
                value: $cornerRadius,
                range: FunctionPlotSettings.cornerRadiusRange,
                step: 1,
                showsSteppers: true
            )
            Toggle(isOn: $transparentBackground) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No background").font(.dsSubheadline).foregroundStyle(theme.ink.color)
                    Text("Just the axes and curve, with no frame or box behind them.")
                        .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
                }
            }
            .padding(.top, 4)
        }
    }

    private var zoomSection: some View {
        sectionBox(title: "Zoom window") {
            HStack(spacing: 12) {
                Button {
                    window = max(FunctionPlotSettings.windowRange.lowerBound, window / 1.4)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Slider(
                    value: $window,
                    in: FunctionPlotSettings.windowRange
                )
                Button {
                    window = min(FunctionPlotSettings.windowRange.upperBound, window * 1.4)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                TextField("", value: $window, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                    .onChange(of: window) { _, newValue in
                        window = min(max(newValue, FunctionPlotSettings.windowRange.lowerBound),
                                     FunctionPlotSettings.windowRange.upperBound)
                    }
            }
            .font(.dsSubheadline)
            .foregroundStyle(theme.ink.color)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Layout helper

    private func sectionBox<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.dsHeadline).foregroundStyle(theme.ink.color)
            content()
        }
        .padding(16)
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Commit

    private func commit() {
        let draftValue = FunctionPlotDraft(
            mode: mode,
            expression: draft,
            secondary: mode.needsSecondaryExpression ? secondaryDraft : nil,
            tertiary: mode.needsTertiaryExpression ? tertiaryDraft : nil,
            window: window,
            axisXLabel: axisX.name,
            axisYLabel: axisCount >= 2 ? axisY.name : nil,
            axisZLabel: axisCount == 3 ? axisZ.name : nil,
            axisXUnit: axisX.unit,
            axisYUnit: axisCount >= 2 ? axisY.unit : nil,
            axisZUnit: axisCount == 3 ? axisZ.unit : nil,
            axisXTickFormat: axisX.tickFormat,
            axisYTickFormat: axisCount >= 2 ? axisY.tickFormat : nil,
            axisZTickFormat: axisCount == 3 ? axisZ.tickFormat : nil,
            axisXTickInterval: axisX.tickInterval,
            axisYTickInterval: axisCount >= 2 ? axisY.tickInterval : nil,
            axisZTickInterval: axisCount == 3 ? axisZ.tickInterval : nil
        )
        onCommit(draftValue, lineColorHex, backgroundColorHex, cornerRadius, transparentBackground)
    }

    // MARK: - Axis count / mode

    private var axisCountBinding: Binding<Int> {
        Binding(
            get: { axisCount },
            set: { newValue in
                switch newValue {
                case 1: mode = .axis
                case 3: mode = .threeD
                default: mode = twoAxisMode
                }
            }
        )
    }

    private var twoAxisModeBinding: Binding<PlotMode> {
        Binding(
            get: { twoAxisMode },
            set: { newValue in
                twoAxisMode = newValue
                mode = newValue
            }
        )
    }

    private func axisDisplay(_ state: AxisFieldState, fallback: String) -> AxisDisplay {
        AxisDisplay(
            label: state.name.isEmpty ? fallback : state.name,
            unit: state.unit.isEmpty ? nil : state.unit,
            tickFormat: state.tickFormat,
            tickInterval: state.tickInterval
        )
    }

    // MARK: - Field rows

    private func fieldRow(_ label: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.dsSubheadline.weight(.semibold)).foregroundStyle(theme.ink.color)
                .frame(minWidth: 56, alignment: .leading)
            TextField("e.g. \(mode.example)", text: text)
                .font(.dsBody.monospaced())
                .foregroundStyle(theme.ink.color)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: field)
        }
    }

    private func axisSettingsRow(title: String, state: Binding<AxisFieldState>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.dsSubheadline.weight(.semibold)).foregroundStyle(theme.ink.color)
            HStack(spacing: 10) {
                TextField(placeholder, text: state.name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                TextField("unit (optional)", text: state.unit)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            }
            Picker("Tick format", selection: state.tickFormat) {
                ForEach(AxisTickFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: state.wrappedValue.tickFormat) { _, _ in
                // A stored interval from the OLD format (say, a plain "5")
                // makes no sense once ticks are formatted as π-fractions —
                // fall back to auto so the new format's own presets apply.
                state.wrappedValue.tickInterval = nil
            }
            Menu {
                Button("Auto") { state.wrappedValue.tickInterval = nil }
                ForEach(state.wrappedValue.tickFormat.intervalPresets, id: \.self) { preset in
                    Button(state.wrappedValue.tickFormat.label(for: preset)) {
                        state.wrappedValue.tickInterval = preset
                    }
                }
            } label: {
                Label(
                    state.wrappedValue.tickInterval.map { "Ticks every \(state.wrappedValue.tickFormat.label(for: $0))" } ?? "Ticks: Auto",
                    systemImage: "ruler"
                )
                .font(.dsCaption.weight(.medium))
            }
        }
    }

    // MARK: - Math keyboard

    private static let mathTokens: [(label: String, insert: String)] = [
        ("√(", "sqrt("), ("^", "^"), ("|x|", "abs("), ("/", "/"),
        ("π", "pi"), ("θ", "theta"), ("sin(", "sin("), ("cos(", "cos("), ("tan(", "tan(")
    ]

    private func insert(_ token: String) {
        switch focusedField {
        case .secondary: secondaryDraft += token
        case .tertiary: tertiaryDraft += token
        case .primary, .none: draft += token
        }
    }
}

private extension PlotMode {
    /// The left-hand side of the equation shown next to the expression field.
    var variableLabel: String {
        switch self {
        case .cartesianY: "y"
        case .cartesianX: "x"
        case .polar: "r"
        case .parametric: "x(t)"
        case .threeD: "x(t)"
        case .axis: ""
        }
    }
}
