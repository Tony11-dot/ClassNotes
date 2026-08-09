import ClassMateTheme
import NotesModels
import SwiftUI

/// A little illustration of one writing instrument for the pen tray.
///
/// Every preset has its OWN instrument — silhouette, material, furniture and nib —
/// not just its own colour: the tray has to tell you which pen is in your hand
/// without opening anything, at a glance, at about 60×24 points.
///
/// Each glyph is built in four passes, which is what makes it read as an object
/// rather than a coloured rectangle with a triangle stuck on the end:
///
/// 1. **Silhouette** — a real barrel profile with curves. Pen bodies dome at the
///    back and narrow into a shoulder; a brush handle tapers the *other* way; a
///    pencil is faceted and cut flat.
/// 2. **Volume** — one shared cylindrical shading pass (highlight high, core
///    shadow low, a bounce at the very bottom) so every barrel looks round.
/// 3. **Furniture** — the parts that name the instrument: a clip, a clicker, a
///    crimped ferrule, hex facets, a paper wrap, a grip.
/// 4. **Nib** — the business end, in the ink's own colour, so one look gives you
///    both *which instrument* and *what's loaded*.
///
/// The art is data-driven through `PenGlyphProfile`, keyed by preset id, so adding
/// an instrument stays a data change.
public struct PenGlyphView: View {
    @Environment(\.theme) var theme

    let preset: PenPreset
    let color: ThemeColor
    /// The selected instrument lifts out of the rail.
    let isSelected: Bool

    public init(preset: PenPreset, color: ThemeColor, isSelected: Bool) {
        self.preset = preset
        self.color = color
        self.isSelected = isSelected
    }

    var profile: PenGlyphProfile { PenGlyphProfile.of(preset) }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let tipWidth = width * profile.tipFraction
            let barrelWidth = width - tipWidth
            let barrelHeight = height * profile.barrelHeightFraction
            // The nib is sized against the BARREL, not the glyph. Sizing it
            // against the glyph gave the thinnest instruments the biggest nibs —
            // the fineliner came out as a sliver of a body behind a nib twice its
            // width, which is the opposite of what a fineliner looks like.
            let tipHeight = min(height, barrelHeight * profile.tipHeightScale)

            HStack(spacing: 0) {
                barrel(width: barrelWidth, height: barrelHeight)
                    .frame(width: barrelWidth, height: barrelHeight)
                nib(width: tipWidth, height: tipHeight)
                    .frame(width: tipWidth, height: tipHeight)
            }
            .frame(width: width, height: height)
            // The instrument lying on a surface: a soft contact shadow under it,
            // and a longer, lower one when it has been picked up.
            .shadow(color: .black.opacity(isSelected ? 0.28 : 0.10),
                    radius: isSelected ? 6 : 2.5, x: isSelected ? -3 : 0, y: isSelected ? 3 : 1)
        }
        .accessibilityLabel(preset.displayName)
    }

    // MARK: - Barrel

    private func barrel(width: CGFloat, height: CGFloat) -> some View {
        let shape = BarrelShape(body: profile.body)
        return shape
            .fill(material(height: height))
            // Volume: the same cylinder light on every instrument, so a tray of
            // nine of them reads as one set under one lamp.
            .overlay { shape.fill(PenGlyphView.cylinderShading) }
            .overlay { furniture(width: width, height: height).clipShape(shape) }
            // Gloss: one long specular streak riding the top third. It is what
            // separates a drawn cylinder from a photographed one, and at tray size
            // it is most of what makes the instrument look like an object.
            .overlay { gloss(width: width, height: height).clipShape(shape) }
            // Furniture that legitimately breaks the silhouette (a clip standing
            // proud of the barrel, a clicker behind it) is drawn unclipped.
            .overlay { proudFurniture(width: width, height: height) }
            .overlay { shape.stroke(theme.separator.color.opacity(0.7), lineWidth: 0.5) }
            .frame(width: width, height: height)
    }

    // MARK: - Furniture (clipped to the barrel)

    @ViewBuilder
    private func furniture(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            switch profile.body {
            case .tapered:
                // Flow pen: an ink band at the shoulder and a fine grip section.
                inkBand(width: width, height: height, at: 0.74, thickness: 0.11)
                gripRibs(width: width, height: height, from: 0.60, count: 3)

            case .slim:
                // Fineliner: one narrow colour ring near the collar, nothing else —
                // the whole point of it is that it's spare.
                inkBand(width: width, height: height, at: 0.82, thickness: 0.07)

            case .clicker:
                inkBand(width: width, height: height, at: 0.70, thickness: 0.13)
                gripRibs(width: width, height: height, from: 0.52, count: 4)

            case .fountain:
                // A wide machined band where the section screws into the barrel.
                metalBand(width: width, height: height, at: 0.70, thickness: 0.16)
                metalBand(width: width, height: height, at: 0.88, thickness: 0.05)

            case .hex:
                hexFacets(width: width, height: height)
                // Ferrule: ridged metal holding the eraser on.
                metalBand(width: width, height: height, at: 0.10, thickness: 0.13)

            case .wax:
                // The crayon's paper sleeve: a label field between two rules.
                Rectangle()
                    .fill(Color.white.opacity(0.86))
                    .frame(width: width * 0.52, height: height * 0.9)
                    .offset(x: width * 0.20)
                    .overlay(alignment: .leading) {
                        VStack(spacing: height * 0.16) {
                            Rectangle().fill(color.color.opacity(0.55))
                                .frame(width: width * 0.34, height: max(0.6, height * 0.055))
                            Rectangle().fill(color.color.opacity(0.35))
                                .frame(width: width * 0.24, height: max(0.6, height * 0.055))
                        }
                        .offset(x: width * 0.29)
                    }

            case .handle:
                // Brush: a crimped ferrule with two crimp lines.
                metalBand(width: width, height: height, at: 0.80, thickness: 0.20)
                Rectangle().fill(.black.opacity(0.16))
                    .frame(width: max(0.5, width * 0.012), height: height)
                    .offset(x: width * 0.85)
                Rectangle().fill(.black.opacity(0.16))
                    .frame(width: max(0.5, width * 0.012), height: height)
                    .offset(x: width * 0.90)

            case .marker:
                // Marker: the cap seam and a colour cuff at the cone.
                Rectangle().fill(.black.opacity(0.12))
                    .frame(width: max(0.5, width * 0.02), height: height)
                    .offset(x: width * 0.46)
                inkBand(width: width, height: height, at: 0.80, thickness: 0.15)

            case .highlighter:
                // Translucent body: the ink level is visible inside it, which is
                // the one detail that makes a highlighter unmistakable.
                Capsule()
                    .fill(color.color.opacity(0.62))
                    .frame(width: width * 0.56, height: height * 0.44)
                    .offset(x: width * 0.16)
                Rectangle().fill(.black.opacity(0.1))
                    .frame(width: max(0.5, width * 0.02), height: height)
                    .offset(x: width * 0.80)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }

    /// Furniture that sits proud of the barrel outline.
    @ViewBuilder
    private func proudFurniture(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            switch profile.body {
            case .tapered, .slim, .fountain:
                clip(width: width, height: height)
            case .clicker:
                clip(width: width, height: height)
                // The plunger, standing out behind the barrel.
                UnevenRoundedRectangle(
                    topLeadingRadius: height * 0.18, bottomLeadingRadius: height * 0.18,
                    style: .continuous
                )
                .fill(color.color)
                .frame(width: width * 0.10, height: height * 0.44)
                .offset(x: -width * 0.07)
            case .hex:
                // Pink eraser behind the ferrule.
                UnevenRoundedRectangle(
                    topLeadingRadius: height * 0.34, bottomLeadingRadius: height * 0.34,
                    style: .continuous
                )
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.96, green: 0.62, blue: 0.64),
                                 Color(red: 0.87, green: 0.48, blue: 0.52)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: width * 0.13, height: height * 0.92)
                .offset(x: -width * 0.10)
            case .wax, .handle, .marker, .highlighter:
                EmptyView()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }

    /// The pocket clip: a thin blade lying along the top of the barrel with a
    /// rolled-over end, standing slightly proud of it.
    private func clip(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(theme.inkSecondary.color.opacity(0.75))
                .frame(width: height * 0.16, height: height * 0.16)
            Capsule()
                .fill(theme.inkSecondary.color.opacity(0.6))
                .frame(width: width * 0.30, height: height * 0.1)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(x: width * 0.14, y: -height * 0.06)
    }

    /// A ring of the ink's own colour.
    private func inkBand(
        width: CGFloat, height: CGFloat, at position: CGFloat, thickness: CGFloat
    ) -> some View {
        Rectangle()
            .fill(color.color)
            .frame(width: width * thickness, height: height)
            .offset(x: width * position)
    }

    /// A machined metal ring — ferrules, collars, cap bands.
    private func metalBand(
        width: CGFloat, height: CGFloat, at position: CGFloat, thickness: CGFloat
    ) -> some View {
        LinearGradient(
            colors: [Color(white: 0.92), Color(white: 0.74), Color(white: 0.55)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(width: width * thickness, height: height)
        .offset(x: width * position)
    }

    /// The moulded grip: a few soft ribs where the fingers go.
    private func gripRibs(
        width: CGFloat, height: CGFloat, from position: CGFloat, count: Int
    ) -> some View {
        HStack(spacing: width * 0.022) {
            ForEach(0..<count, id: \.self) { _ in
                Capsule()
                    .fill(.black.opacity(0.14))
                    .frame(width: max(0.6, width * 0.016), height: height * 0.66)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .offset(x: width * position)
    }

    /// The pencil's facets: two lines running the length of the wood.
    private func hexFacets(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: height * 0.30) {
            Rectangle().fill(.black.opacity(0.10)).frame(height: max(0.5, height * 0.035))
            Rectangle().fill(.black.opacity(0.07)).frame(height: max(0.5, height * 0.035))
        }
        .frame(width: width, height: height, alignment: .center)
    }

    // MARK: - Nib

    @ViewBuilder
    private func nib(width: CGFloat, height: CGFloat) -> some View {
        switch profile.tip {
        case .ball:
            // A cone with the ball itself standing at its point — overlapping the
            // apex, so it reads as one tip rather than a bead floating off the end.
            ZStack(alignment: .trailing) {
                ConeTipShape().fill(color.color)
                Circle()
                    .fill(color.color)
                    .frame(width: height * 0.36, height: height * 0.36)
            }
        case .needle:
            // The fineliner's giveaway: a metal cone running out into a long,
            // parallel needle.
            ZStack {
                NeedleTipShape().fill(color.color)
                NeedleCollarShape()
                    .fill(LinearGradient(
                        colors: [Color(white: 0.9), Color(white: 0.6)],
                        startPoint: .top, endPoint: .bottom
                    ))
            }
        case .nib:
            // A split nib: shoulders, a breather hole, and the slit down to the tip.
            ZStack {
                NibShape().fill(color.color)
                NibShape().strokeBorder(theme.separator.color.opacity(0.8), lineWidth: 0.4)
                Circle()
                    .fill(theme.paper.color.opacity(0.85))
                    .frame(width: height * 0.13, height: height * 0.13)
                    .offset(x: -width * 0.16)
                Rectangle()
                    .fill(theme.paper.color.opacity(0.7))
                    .frame(width: width * 0.42, height: max(0.5, height * 0.045))
                    .offset(x: width * 0.06)
            }
        case .chisel:
            ChiselShape().fill(color.color)
        case .wideChisel:
            ChiselShape().fill(color.withAlpha(max(0.45, color.alpha)).color)
        case .wood:
            // Sharpened wood with the graphite cone standing out of it.
            ZStack {
                WoodTipShape().fill(
                    LinearGradient(
                        colors: [Color(red: 0.93, green: 0.82, blue: 0.62),
                                 Color(red: 0.80, green: 0.64, blue: 0.42)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                GraphiteTipShape().fill(color.color)
            }
        case .waxStub:
            WaxTipShape().fill(color.color)
        case .bristle:
            // Bristles: a soft belly narrowing to a point. The lighter core is the
            // sheen down the middle of the hair, not a stain on one side.
            ZStack {
                BrushTipShape().fill(
                    LinearGradient(
                        colors: [color.color.opacity(0.82), color.color],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                BrushTipShape()
                    .fill(.white.opacity(0.20))
                    .scaleEffect(x: 0.96, y: 0.4, anchor: .center)
                BrushTipShape().stroke(.black.opacity(0.10), lineWidth: 0.5)
            }
        }
    }
}
