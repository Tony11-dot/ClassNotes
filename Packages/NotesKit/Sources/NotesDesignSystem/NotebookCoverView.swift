import ClassMateTheme
import NotesModels
import SwiftUI
import UIKit

/// A themed notebook cover: the chosen cover color, one of the `CoverDesign`
/// artworks drawn procedurally on top, a subtle spine, and a legible title.
/// Content layer — opaque by design, and asset-free so it stays crisp from a
/// 60 pt picker chip to a full-screen preview.
///
/// The cover is page one of the document, so anything drawn on it belongs on this
/// tile too: pass `render` (the PNG the editor writes beside the pages) and the
/// tile shows the real, drawn-on cover instead of re-deriving the artwork.
public struct NotebookCoverView: View {
    let title: String
    let coverColor: ThemeColor
    let design: CoverDesign
    /// Hidden for the "Cover: off" notebooks, where the library shows page one.
    let showsTitle: Bool
    /// The rendered cover page (artwork + ink), when one has been saved.
    let render: UIImage?

    public init(
        title: String,
        coverColor: ThemeColor,
        design: CoverDesign = .default,
        showsTitle: Bool = true,
        render: UIImage? = nil
    ) {
        self.title = title
        self.coverColor = coverColor
        self.design = design
        self.showsTitle = showsTitle
        self.render = render
    }

    public var body: some View {
        Group {
            if let render {
                // The render already contains artwork, title and ink.
                Image(uiImage: render)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                CoverPaperView(
                    cover: CoverPaper(
                        title: title,
                        coverColorHex: coverColor.hexString,
                        design: design,
                        showsTitle: showsTitle
                    ),
                    coverColorOverride: coverColor
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .accessibilityLabel("Notebook \(title), \(design.displayName) cover")
    }
}

/// The cover artwork as a SURFACE that fills whatever it's given: the library
/// tile clips it to a 3:4 card, and the editor uses it as page one's paper, where
/// it fills the page and takes ink on top. Opaque, like all paper.
public struct CoverPaperView: View {
    @Environment(\.theme) private var theme

    let cover: CoverPaper
    /// Used by the cover picker, which previews palette entries that aren't the
    /// notebook's saved hex.
    let coverColorOverride: ThemeColor?

    public init(cover: CoverPaper, coverColorOverride: ThemeColor? = nil) {
        self.cover = cover
        self.coverColorOverride = coverColorOverride
    }

    private var coverColor: ThemeColor {
        coverColorOverride ?? ThemeColor(hex: cover.coverColorHex) ?? theme.accent
    }

    public var body: some View {
        let ink = theme.contrastingInk(on: coverColor)
        GeometryReader { geo in
            // Everything is sized from the surface's own width, so one drawing
            // reads correctly as a 60 pt picker chip, a 200 pt library tile and a
            // full A4 page in the editor.
            let unit = max(geo.size.width, 1) / 200
            Rectangle()
                .fill(coverColor.color.gradient)
                .overlay { CoverArtView(design: cover.design, coverColor: coverColor) }
                .overlay(alignment: .leading) { spine(unit: unit) }
                .overlay(alignment: cover.design.hasTitlePlate ? .center : .bottomLeading) {
                    if cover.showsTitle { titleView(ink: ink, unit: unit) }
                }
        }
    }

    private var title: String { cover.title }
    private var design: CoverDesign { cover.design }

    private func spine(unit: CGFloat) -> some View {
        Rectangle()
            .fill(.black.opacity(0.14))
            .frame(width: 10 * unit)
    }

    @ViewBuilder
    private func titleView(ink: ThemeColor, unit: CGFloat) -> some View {
        let font = Font.dsSystem(size: 17 * unit, weight: .semibold)
        if design.hasTitlePlate {
            // Classic stationery: the title sits on a printed label.
            Text(title)
                .font(font)
                .foregroundStyle(theme.ink.color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14 * unit)
                .padding(.vertical, 12 * unit)
                .frame(maxWidth: .infinity)
                .background(theme.paper.color.opacity(0.94))
                .overlay(
                    Rectangle()
                        .strokeBorder(theme.ink.withAlpha(0.15).color, lineWidth: 1 * unit)
                )
                .padding(.horizontal, 22 * unit)
                .shadow(color: .black.opacity(0.12), radius: 4 * unit, y: 2 * unit)
        } else {
            Text(title)
                .font(font)
                .foregroundStyle(ink.color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.leading, 20 * unit)
                .padding([.bottom, .trailing], 12 * unit)
        }
    }
}

/// What sits UNDER a page's ink: the notebook's cover artwork when the page is
/// the cover, the printed paper template otherwise.
///
/// One view so the editor, the iPhone viewer, the page manager and every export
/// composite agree on what a page looks like — the cover is a page, and it has to
/// look like the cover everywhere it's drawn.
public struct PagePaperView: View {
    let page: PageRecord
    let cover: CoverPaper?

    public init(page: PageRecord, cover: CoverPaper?) {
        self.page = page
        self.cover = cover
    }

    public var body: some View {
        if page.isCover, let cover {
            CoverPaperView(cover: cover)
        } else {
            PageTemplateView(style: page.style)
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
