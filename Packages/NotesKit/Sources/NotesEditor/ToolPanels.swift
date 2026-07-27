import ClassMateTheme
import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftUI
import UniformTypeIdentifiers

// The panels that pop out of the tool rail: one per instrument, plus tape, text
// boxes, beautification and page settings. Split out of ToolRailView to keep
// each file focused.

// MARK: - Shared controls

/// A labelled slider with a value readout on the right — the shape every control
/// in these panels uses, so the panels read as one system.
struct PanelSlider: View {
    @Environment(\.theme) private var theme

    let title: String
    let readout: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    /// Shows −/+ steppers beside the readout (the "Thickness" row).
    var showsSteppers = false
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.dsSubheadline.weight(.medium))
                    .foregroundStyle(theme.ink.color)
                if let hint {
                    Image(systemName: "questionmark.circle")
                        .font(.dsCaption)
                        .foregroundStyle(theme.accent.color)
                        .help(hint)
                        .accessibilityLabel(hint)
                }
                Spacer()
                if showsSteppers {
                    stepper(-1)
                }
                Text(readout)
                    .font(.dsSubheadline.monospacedDigit())
                    .foregroundStyle(theme.inkSecondary.color)
                if showsSteppers {
                    stepper(1)
                }
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }

    private func stepper(_ direction: Double) -> some View {
        Button {
            let delta = (step ?? (range.upperBound - range.lowerBound) / 40) * direction
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        } label: {
            Image(systemName: direction > 0 ? "plus.circle" : "minus.circle")
                .font(.dsSystem(size: 17))
                .foregroundStyle(theme.accent.color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction > 0 ? "Increase \(title)" : "Decrease \(title)")
    }
}

/// The stability slider's bounds as doubles — spelled out here so the range
/// operator stays on one line and the call sites read cleanly.
let penStabilityRange: ClosedRange<Double> =
    Double(PenSettings.stabilityRange.lowerBound)...Double(PenSettings.stabilityRange.upperBound)

/// The page line-spacing slider's bounds as doubles.
let pageSpacingRange: ClosedRange<Double> =
    Double(PageLineSpacing.range.lowerBound)...Double(PageLineSpacing.range.upperBound)

/// The header every panel shares: an optional leading action, a title, and an
/// optional trailing action.
struct PanelHeader: View {
    @Environment(\.theme) private var theme

    let title: String
    var leading: (label: String, action: () -> Void)?
    var trailing: (label: String, action: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                if let leading {
                    Button(leading.label, action: leading.action)
                        .font(.dsSubheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent.color)
                } else {
                    Spacer().frame(width: 44)
                }
                Spacer()
                Text(title)
                    .font(.dsHeadline)
                    .foregroundStyle(theme.ink.color)
                Spacer()
                if let trailing {
                    Button(trailing.label, action: trailing.action)
                        .font(.dsSubheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent.color)
                } else {
                    Spacer().frame(width: 44)
                }
            }
            Divider().overlay(theme.separator.color)
        }
    }
}

// MARK: - Pen settings

/// One instrument's settings: a live preview of the stroke, then the tuning that
/// actually reshapes it — stability, tip, pressure sensitivity, thickness,
/// concentration — and its colour.
struct PenSettingsPanel: View {
    @Environment(\.theme) private var theme

    let toolState: ToolState
    let preset: PenPreset

    @State private var showAdvanced = false

    private var settings: PenSettings { toolState.settings(for: preset) }

    private var color: ThemeColor {
        settings.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(
                    title: preset.displayName,
                    leading: ("Reset", { toolState.resetPen(preset) }),
                    trailing: (showAdvanced ? "Basic" : "Advanced", { showAdvanced.toggle() })
                )

                StrokePreview(
                    color: color, width: settings.effectiveWidth,
                    opacity: settings.concentration, stability: settings.stability
                )

                PanelSlider(
                    title: "Stability",
                    readout: "\(settings.stability)",
                    value: binding(\.stability),
                    range: penStabilityRange,
                    step: 1,
                    hint: "Smooths the line as you write. Higher settles a shaky hand."
                )

                PanelSlider(
                    title: "Tip",
                    readout: "\(Int((settings.tip * 100).rounded()))%",
                    value: binding(\.tip),
                    range: 0.05...1
                )

                PanelSlider(
                    title: "Sensitivity",
                    readout: "\(Int((settings.sensitivity * 100).rounded()))%",
                    value: binding(\.sensitivity),
                    range: 0...1,
                    hint: "How much pressure changes the stroke width."
                )

                PanelSlider(
                    title: "Thickness",
                    readout: String(format: "%.1f", settings.thickness),
                    value: binding(\.thickness),
                    range: preset.widthRange,
                    step: 0.2,
                    showsSteppers: true
                )

                PanelSlider(
                    title: "Concentration",
                    readout: "\(Int((settings.concentration * 100).rounded()))%",
                    value: binding(\.concentration),
                    range: 0.05...1
                )

                Divider().overlay(theme.separator.color)

                Text("Color").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
                ColorSwatchRow(
                    swatches: toolState.inkPalette(theme: theme).map(\.hexString),
                    selection: colorBinding
                )

                if showAdvanced {
                    Divider().overlay(theme.separator.color)
                    Toggle(isOn: Binding(
                        get: { toolState.scribbleToErase },
                        set: { toolState.scribbleToErase = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scribble to erase")
                                .font(.dsSubheadline).foregroundStyle(theme.ink.color)
                            Text("Scrub back and forth over something to rub it out.")
                                .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { toolState.snapShapes },
                        set: { toolState.snapShapes = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Snap shapes")
                                .font(.dsSubheadline).foregroundStyle(theme.ink.color)
                            Text("Hold at the end of a stroke to straighten it into a shape.")
                                .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 288)
        .frame(maxHeight: 620)
        .background(theme.surfaceRaised.color)
    }

    private var colorBinding: Binding<String?> {
        Binding(
            get: { settings.colorHex ?? theme.ink.hexString },
            set: { hex in
                var updated = settings
                updated.colorHex = hex ?? theme.ink.hexString
                toolState.setSettings(updated, for: preset)
            }
        )
    }

    /// Writes one numeric field back into the instrument's tuning.
    private func binding(_ keyPath: WritableKeyPath<PenSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                var updated = settings
                updated[keyPath: keyPath] = value
                toolState.setSettings(updated, for: preset)
            }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<PenSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(settings[keyPath: keyPath]) },
            set: { value in
                var updated = settings
                updated[keyPath: keyPath] = Int(value.rounded())
                toolState.setSettings(updated, for: preset)
            }
        )
    }
}

// MARK: - Tape

/// The sticky-tape panel: how the strip is laid down, how thick it is, its
/// pattern and colour, and the two study shortcuts — lift every strip at once, or
/// put them all back.
struct TapePanel: View {
    @Environment(\.theme) private var theme

    @Bindable var toolState: ToolState
    /// `true` lifts every strip on the page (reveal), `false` covers them again.
    let onVisibility: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(
                    title: "Tape Type",
                    leading: ("Reset", {
                        toolState.tapeShape = .draw
                        toolState.tapePattern = .stripes
                        toolState.tapeThickness = TapeGeometry.defaultThickness
                        toolState.tapeColorHex = nil
                    })
                )

                HStack(spacing: 18) {
                    ForEach(TapeShape.allCases) { shape in
                        shapeButton(shape)
                    }
                }
                .frame(maxWidth: .infinity)

                PanelSlider(
                    title: "Thickness",
                    readout: String(format: "%.0f", toolState.tapeThickness),
                    value: $toolState.tapeThickness,
                    range: TapeGeometry.minThickness...TapeGeometry.maxThickness,
                    step: 1,
                    showsSteppers: true
                )
                .disabled(toolState.tapeShape == .rectangle)
                .opacity(toolState.tapeShape == .rectangle ? 0.45 : 1)

                Text("Pattern").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(TapePattern.allCases) { pattern in
                            Button { toolState.tapePattern = pattern } label: {
                                TapePatternSwatch(
                                    pattern: pattern,
                                    color: toolState.tapeColor(theme: theme),
                                    isSelected: toolState.tapePattern == pattern
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider().overlay(theme.separator.color)

                Text("Color").font(.dsSubheadline.weight(.medium)).foregroundStyle(theme.ink.color)
                ColorSwatchRow(
                    swatches: theme.coverPalette.prefix(9).map(\.hexString),
                    selection: $toolState.tapeColorHex,
                    includesAuto: true,
                    showsOpacity: true
                )

                Divider().overlay(theme.separator.color)

                visibilityRow("All Hidden", systemImage: "eye.slash") { onVisibility(true) }
                visibilityRow("All Display", systemImage: "eye") { onVisibility(false) }

                Label {
                    Text("Tap a strip to reveal what's under it, tap again to cover it. "
                         + "Long-press a strip to delete it, or set the eraser to “Tape only”.")
                        .font(.dsCaption)
                        .foregroundStyle(theme.inkSecondary.color)
                } icon: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(theme.inkSecondary.color)
                }
            }
            .padding(18)
        }
        .frame(width: 288)
        .frame(maxHeight: 620)
        .background(theme.surfaceRaised.color)
    }

    private func shapeButton(_ shape: TapeShape) -> some View {
        let isOn = toolState.tapeShape == shape
        return Button { toolState.tapeShape = shape } label: {
            VStack(spacing: 6) {
                Image(systemName: shape.symbolName)
                    .font(.dsSystem(size: 19))
                    .foregroundStyle(isOn ? theme.accent.color : theme.ink.color)
                    .frame(width: 52, height: 52)
                    .background(
                        isOn ? theme.accentMuted.color : theme.surface.color,
                        in: Circle()
                    )
                    .overlay(Circle().strokeBorder(
                        isOn ? theme.accent.color : theme.separator.color,
                        lineWidth: isOn ? 1.5 : 0.5
                    ))
                Text(shape.displayName)
                    .font(.dsCaption2)
                    .foregroundStyle(isOn ? theme.accent.color : theme.inkSecondary.color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func visibilityRow(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.dsSubheadline).foregroundStyle(theme.ink.color)
                Spacer()
                Image(systemName: systemImage).foregroundStyle(theme.ink.color)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Eraser

struct EraserPanel: View {
    @Environment(\.theme) private var theme
    @Bindable var toolState: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: "Eraser")
            Picker("Mode", selection: $toolState.eraserMode) {
                ForEach(ToolState.EraserMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            switch toolState.eraserMode {
            case .pixel:
                PanelSlider(
                    title: "Size",
                    readout: "\(Int(toolState.eraserWidth.rounded())) pt",
                    value: $toolState.eraserWidth,
                    range: 6...60,
                    step: 1
                )
            case .stroke:
                Text("Removes a whole stroke on contact. Undo brings it back.")
                    .font(.dsSubheadline).foregroundStyle(theme.inkSecondary.color)
            case .tapeOnly:
                Text("Only lifts tape. Tap a strip to peel it off; the ink underneath is untouched.")
                    .font(.dsSubheadline).foregroundStyle(theme.inkSecondary.color)
            }

            Divider().overlay(theme.separator.color)

            Toggle(isOn: $toolState.scribbleToErase) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scribble to erase").font(.dsSubheadline).foregroundStyle(theme.ink.color)
                    Text("With any pen, scrub back and forth over something to rub it out.")
                        .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
                }
            }
        }
        .padding(18)
        .frame(width: 272)
        .background(theme.surfaceRaised.color)
    }
}

