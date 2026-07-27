import ClassMateTheme
import NotesModels
import SwiftUI

/// A themed notebook cover: the chosen cover color, one of the `CoverDesign`
/// artworks drawn procedurally on top, a subtle spine, and a legible title.
/// Content layer — opaque by design, and asset-free so it stays crisp from a
/// 60 pt picker chip to a full-screen preview.
public struct NotebookCoverView: View {
    @Environment(\.theme) private var theme

    let title: String
    let coverColor: ThemeColor
    let design: CoverDesign
    /// Hidden for the "Cover: off" notebooks, where the library shows page one.
    let showsTitle: Bool

    public init(
        title: String,
        coverColor: ThemeColor,
        design: CoverDesign = .default,
        showsTitle: Bool = true
    ) {
        self.title = title
        self.coverColor = coverColor
        self.design = design
        self.showsTitle = showsTitle
    }

    public var body: some View {
        let ink = theme.contrastingInk(on: coverColor)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(coverColor.color.gradient)
            .overlay { CoverArtView(design: design, coverColor: coverColor) }
            .overlay(alignment: .leading) { spine }
            .overlay(alignment: design.hasTitlePlate ? .center : .bottomLeading) {
                if showsTitle { titleView(ink: ink) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .accessibilityLabel("Notebook \(title), \(design.displayName) cover")
    }

    private var spine: some View {
        Rectangle()
            .fill(.black.opacity(0.14))
            .frame(width: 10)
            .clipShape(
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
            )
    }

    @ViewBuilder
    private func titleView(ink: ThemeColor) -> some View {
        if design.hasTitlePlate {
            // Classic stationery: the title sits on a printed label.
            Text(title)
                .font(.dsHeadline)
                .foregroundStyle(theme.ink.color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(theme.paper.color.opacity(0.94))
                .overlay(Rectangle().strokeBorder(theme.ink.withAlpha(0.15).color, lineWidth: 1))
                .padding(.horizontal, 22)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        } else {
            Text(title)
                .font(.dsHeadline)
                .foregroundStyle(ink.color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.leading, 20)
                .padding([.bottom, .trailing], 12)
        }
    }
}

/// The procedural artwork for one cover design, drawn from shades of the cover
/// color so every design works with every palette entry.
public struct CoverArtView: View {
    let design: CoverDesign
    let coverColor: ThemeColor

    public init(design: CoverDesign, coverColor: ThemeColor) {
        self.design = design
        self.coverColor = coverColor
    }

    /// Light/dark ink derived from the cover itself: patterns read as printing on
    /// the stock rather than as unrelated colors.
    var isDarkCover: Bool { coverColor.relativeLuminance < 0.42 }
    var motif: Color { (isDarkCover ? Color.white : Color.black).opacity(0.14) }
    var motifStrong: Color { (isDarkCover ? Color.white : Color.black).opacity(0.26) }
    var glow: Color { (isDarkCover ? Color.white : Color.white).opacity(0.3) }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            switch design {
            case .simple1, .simple2, .simple3, .simple4:
                simpleArt(size)
            case .composition, .ledger, .labelled, .index:
                classicArt(size)
            case .stripes, .pinstripe, .checks, .dots, .gridlines, .diamonds, .arches, .waves:
                Canvas { context, canvasSize in patternArt(context, canvasSize) }
            case .dusk, .sunrise, .aurora, .halo:
                gradientArt(size)
            case .linen, .kraft, .marble, .carbon:
                Canvas { context, canvasSize in textureArt(context, canvasSize) }
            case .confetti, .bloom, .stars, .terrazzo:
                Canvas { context, canvasSize in playfulArt(context, canvasSize) }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Simple

    @ViewBuilder
    private func simpleArt(_ size: CGSize) -> some View {
        switch design {
        case .simple2:
            // A single rule near the top — the plainest "notebook" mark.
            Rectangle().fill(motif).frame(height: 1.2)
                .padding(.horizontal, size.width * 0.14)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, size.height * 0.16)
        case .simple3:
            // Stacked rules at the foot, like a page corner.
            VStack(alignment: .trailing, spacing: size.height * 0.018) {
                ForEach(0..<4, id: \.self) { _ in
                    Rectangle().fill(motif).frame(width: size.width * 0.3, height: 1.2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, size.width * 0.12)
            .padding(.bottom, size.height * 0.16)
        case .simple4:
            // A soft debossed panel.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(motif, lineWidth: 1.2)
                .padding(.horizontal, size.width * 0.1)
                .padding(.vertical, size.height * 0.08)
        default:
            // simple1 — a bare stock with a top rule and foot rules, as shipped.
            ZStack {
                Rectangle().fill(motif).frame(height: 1.2)
                    .padding(.horizontal, size.width * 0.12)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, size.height * 0.14)
                VStack(alignment: .trailing, spacing: size.height * 0.015) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(motif).frame(width: size.width * 0.26, height: 1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, size.width * 0.1)
                .padding(.bottom, size.height * 0.18)
            }
        }
    }

    // MARK: - Classic stationery

    @ViewBuilder
    private func classicArt(_ size: CGSize) -> some View {
        switch design {
        case .composition:
            // Marbled speckle, the school composition book.
            Canvas { context, canvasSize in
                var generator = SeededRandom(seed: 41)
                for _ in 0..<420 {
                    let x = generator.next() * canvasSize.width
                    let y = generator.next() * canvasSize.height
                    let radius = 0.8 + generator.next() * 2.2
                    let rect = CGRect(x: x, y: y, width: radius, height: radius * 1.4)
                    context.fill(Path(ellipseIn: rect), with: .color(motifStrong))
                }
            }
        case .ledger:
            Canvas { context, canvasSize in
                let spacing = canvasSize.height / 16
                var y = spacing
                while y < canvasSize.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                    context.stroke(path, with: .color(motif), lineWidth: 0.9)
                    y += spacing
                }
                var path = Path()
                path.move(to: CGPoint(x: canvasSize.width * 0.78, y: 0))
                path.addLine(to: CGPoint(x: canvasSize.width * 0.78, y: canvasSize.height))
                context.stroke(path, with: .color(motifStrong), lineWidth: 1.2)
            }
        case .index:
            // Tabbed index card look: a band down the top and a side tab.
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(motif)
                    .frame(height: size.height * 0.1)
                    .frame(maxHeight: .infinity, alignment: .top)
                RoundedRectangle(cornerRadius: 3)
                    .fill(motifStrong)
                    .frame(width: size.width * 0.08, height: size.height * 0.16)
                    .padding(.trailing, size.width * 0.08)
                    .padding(.top, size.height * 0.14)
            }
        default:
            // labelled — twin rules framing where the label sits.
            VStack {
                Rectangle().fill(motif).frame(height: 1.2)
                Spacer()
                Rectangle().fill(motif).frame(height: 1.2)
            }
            .padding(.horizontal, size.width * 0.08)
            .padding(.vertical, size.height * 0.1)
        }
    }

}

/// A tiny deterministic generator so procedural cover art (and tape patterns)
/// look identical every render — `Math.random` equivalents would make covers
/// shimmer on every redraw and break render tests.
struct SeededRandom {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        if state == 0 { state = 0x9E37_79B9_7F4A_7C15 }
    }

    /// Next value in `0..<1`.
    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 100_000) / 100_000
    }
}
