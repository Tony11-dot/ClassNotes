import ClassMateTheme
import SwiftUI

/// HSB conversion for the color wheel. Kept here (not in `ClassMateTheme`) because
/// it exists purely to drive a picker, not to define any theme value.
extension ThemeColor {
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0.00001 {
            if maxValue == red {
                hue = (green - blue) / delta
            } else if maxValue == green {
                hue = 2 + (blue - red) / delta
            } else {
                hue = 4 + (red - green) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue <= 0 ? 0 : delta / maxValue
        return (hue, saturation, maxValue)
    }

    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h)
        let f = h - Double(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch sector % 6 {
        case 0: self.init(red: brightness, green: t, blue: p, alpha: alpha)
        case 1: self.init(red: q, green: brightness, blue: p, alpha: alpha)
        case 2: self.init(red: p, green: brightness, blue: t, alpha: alpha)
        case 3: self.init(red: p, green: q, blue: brightness, alpha: alpha)
        case 4: self.init(red: t, green: p, blue: brightness, alpha: alpha)
        default: self.init(red: brightness, green: p, blue: q, alpha: alpha)
        }
    }
}

/// A real color wheel: drag anywhere on the hue/saturation disc, then set
/// brightness and opacity underneath. This is what the `+` in every color row
/// opens, so any color in the app can be a custom one.
public struct ColorWheelPicker: View {
    @Environment(\.theme) private var theme

    @Binding var color: ThemeColor
    /// Hidden for pen/line colors, where a translucent value makes no sense.
    let showsOpacity: Bool
    let onCommit: (ThemeColor) -> Void

    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var opacity: Double = 1

    public init(
        color: Binding<ThemeColor>,
        showsOpacity: Bool = false,
        onCommit: @escaping (ThemeColor) -> Void = { _ in }
    ) {
        self._color = color
        self.showsOpacity = showsOpacity
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(spacing: 16) {
            wheel
                .frame(width: 200, height: 200)

            slider(
                title: "Brightness", value: $brightness,
                gradient: Gradient(colors: [
                    .black, ThemeColor(hue: hue, saturation: saturation, brightness: 1).color
                ])
            )

            if showsOpacity {
                slider(
                    title: "Opacity", value: $opacity,
                    gradient: Gradient(colors: [
                        .clear, ThemeColor(hue: hue, saturation: saturation, brightness: brightness).color
                    ])
                )
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(current.color)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(theme.separator.color, lineWidth: 0.5))
                Text(current.hexString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(theme.inkSecondary.color)
                Spacer()
                Button("Use") { onCommit(current) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .frame(width: 250)
        .background(theme.surfaceRaised.color)
        .onAppear { load(from: color) }
        .onChange(of: brightness) { _, _ in push() }
        .onChange(of: opacity) { _, _ in push() }
    }

    private var current: ThemeColor {
        ThemeColor(
            hue: hue, saturation: saturation, brightness: brightness,
            alpha: showsOpacity ? opacity : 1
        )
    }

    private func load(from value: ThemeColor) {
        let components = value.hsb
        hue = components.hue
        saturation = components.saturation
        // A pure black seed would pin the wheel dark with no way back up.
        brightness = max(components.brightness, 0.08)
        opacity = value.alpha
    }

    private func push() {
        color = current
    }

    private var wheel: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let center = CGPoint(x: radius, y: radius)
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: (0...12).map {
                                ThemeColor(hue: Double($0) / 12, saturation: 1, brightness: 1).color
                            }),
                            center: .center
                        )
                    )
                    .overlay(
                        Circle().fill(
                            RadialGradient(
                                colors: [.white, .white.opacity(0)],
                                center: .center, startRadius: 0, endRadius: radius
                            )
                        )
                    )
                    .overlay(Circle().strokeBorder(theme.separator.color, lineWidth: 0.5))
                    .brightness(brightness - 1)

                knob(center: center, radius: radius)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in select(value.location, center: center, radius: radius) }
            )
        }
    }

    private func knob(center: CGPoint, radius: CGFloat) -> some View {
        let angle = hue * 2 * .pi
        let distance = saturation * radius
        let position = CGPoint(
            x: center.x + cos(angle) * distance,
            y: center.y + sin(angle) * distance
        )
        return Circle()
            .strokeBorder(.white, lineWidth: 3)
            .background(Circle().fill(current.color))
            .frame(width: 24, height: 24)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .position(position)
    }

    private func select(_ point: CGPoint, center: CGPoint, radius: CGFloat) {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = min(hypot(dx, dy), radius)
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        hue = angle / (2 * .pi)
        saturation = radius > 0 ? distance / radius : 0
        push()
    }

    private func slider(title: String, value: Binding<Double>, gradient: Gradient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(theme.inkSecondary.color)
            ZStack {
                Capsule()
                    .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 12)
                    .overlay(Capsule().strokeBorder(theme.separator.color, lineWidth: 0.5))
                Slider(value: value, in: 0.02...1)
                    .tint(.clear)
            }
        }
    }
}

/// A row of color swatches with an optional "Auto" entry and a trailing `+` that
/// opens the color wheel. Used by paper color, line color, pen color and tape
/// color, so every color surface in the app behaves the same way.
public struct ColorSwatchRow: View {
    @Environment(\.theme) private var theme

    /// Hex values offered as presets.
    let swatches: [String]
    /// When true the row leads with an "Auto" chip that binds `nil`.
    let includesAuto: Bool
    let showsOpacity: Bool
    @Binding var selection: String?

    @State private var showWheel = false
    @State private var custom: ThemeColor = ThemeColor(red: 0.2, green: 0.5, blue: 0.9)
    /// Colors the user mixed on the wheel, kept for the rest of the session so a
    /// custom color can be reused without mixing it twice.
    @State private var recents: [String] = []

    private let swatchSize: CGFloat = 30

    public init(
        swatches: [String],
        selection: Binding<String?>,
        includesAuto: Bool = false,
        showsOpacity: Bool = false
    ) {
        self.swatches = swatches
        self._selection = selection
        self.includesAuto = includesAuto
        self.showsOpacity = showsOpacity
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if includesAuto { autoChip }
                ForEach(swatches + recents, id: \.self) { hex in
                    chip(hex: hex)
                }
                plusChip
            }
            .padding(.vertical, 4)
        }
    }

    private var autoChip: some View {
        Button { selection = nil } label: {
            ZStack {
                Circle().fill(theme.paperColor(tone: .neutral).color)
                Image(systemName: "a.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.inkSecondary.color)
            }
            .frame(width: swatchSize, height: swatchSize)
            .overlay(ring(isSelected: selection == nil))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Automatic color")
    }

    private func chip(hex: String) -> some View {
        let isSelected = selection?.caseInsensitiveCompare(hex) == .orderedSame
        return Button { selection = hex } label: {
            Circle()
                .fill(ThemeColor(hex: hex)?.color ?? theme.ink.color)
                .frame(width: swatchSize, height: swatchSize)
                .overlay(Circle().strokeBorder(theme.separator.color, lineWidth: 0.5))
                .overlay(ring(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(hex)")
    }

    private var plusChip: some View {
        Button {
            custom = selection.flatMap(ThemeColor.init(hex:)) ?? theme.accent
            showWheel = true
        } label: {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: (0...8).map {
                                ThemeColor(hue: Double($0) / 8, saturation: 0.85, brightness: 1).color
                            }),
                            center: .center
                        )
                    )
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1)
            }
            .frame(width: swatchSize, height: swatchSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Custom color")
        .popover(isPresented: $showWheel) {
            ColorWheelPicker(color: $custom, showsOpacity: showsOpacity) { picked in
                let hex = picked.hexString
                if !swatches.contains(hex), !recents.contains(hex) {
                    recents.append(hex)
                    if recents.count > 6 { recents.removeFirst() }
                }
                selection = hex
                showWheel = false
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private func ring(isSelected: Bool) -> some View {
        Circle().strokeBorder(theme.accent.color, lineWidth: isSelected ? 2.5 : 0)
            .padding(-3)
    }
}
