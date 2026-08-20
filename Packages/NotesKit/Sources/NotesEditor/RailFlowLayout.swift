import SwiftUI

/// Wraps a run of same-family, differently-sized buttons (write, pens, rail
/// actions) into as many lines as the available space actually holds, instead
/// of one fixed-length strip.
///
/// The tool rail used to be a single `VStack` because it only ever docked to
/// the left/right edge, where a tall, narrow, one-wide column already fits
/// the available height reasonably (if not always exactly). Docking it to the
/// top/bottom edge instead needs the OPPOSITE shape — short and wide — and
/// neither a `VStack` nor a `HStack` adapts: a plain `HStack` of every button
/// in the rail is wider than any iPad screen. This lays a `.vertical` rail out
/// as columns (filling down, wrapping right when a column would run past the
/// proposed height) and a `.horizontal` rail as rows (filling across,
/// wrapping down when a row would run past the proposed width) — so "does it
/// fit" is answered by actually measuring each button's own size against the
/// space on offer, the same idea a real flow layout uses, rather than
/// assuming a fixed cell size or a fixed line count either could silently
/// overflow past.
struct RailFlowLayout: Layout {
    var axis: Axis
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = arrange(sizes, proposal: proposal)
        return boundingSize(of: lines)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = arrange(sizes, proposal: proposal)
        switch axis {
        case .vertical:
            var x = bounds.minX
            for line in lines {
                var y = bounds.minY
                for index in line.indices {
                    let size = sizes[index]
                    subviews[index].place(
                        at: CGPoint(x: x + (line.crossExtent - size.width) / 2, y: y),
                        proposal: ProposedViewSize(size)
                    )
                    y += size.height + spacing
                }
                x += line.crossExtent + spacing
            }
        case .horizontal:
            var y = bounds.minY
            for line in lines {
                var x = bounds.minX
                for index in line.indices {
                    let size = sizes[index]
                    subviews[index].place(
                        at: CGPoint(x: x, y: y + (line.crossExtent - size.height) / 2),
                        proposal: ProposedViewSize(size)
                    )
                    x += size.width + spacing
                }
                y += line.crossExtent + spacing
            }
        }
    }

    /// One line (a column for `.vertical`, a row for `.horizontal`): the
    /// subview indices it holds, how far it runs along the PRIMARY axis
    /// (height for a column, width for a row), and how thick it is along the
    /// CROSS axis (the widest item in a column, the tallest in a row) — which
    /// is also the offset the next line starts at.
    private struct Line {
        var indices: [Int] = []
        var primaryExtent: CGFloat = 0
        var crossExtent: CGFloat = 0
    }

    /// Greedily fills the PRIMARY axis of one line until the next item would
    /// overflow the proposed extent, then starts a new line — the same wrap
    /// rule a text paragraph uses, just applied to buttons instead of words.
    private func arrange(_ sizes: [CGSize], proposal: ProposedViewSize) -> [Line] {
        let primaryLimit: CGFloat = {
            switch axis {
            case .vertical: proposal.height ?? .infinity
            case .horizontal: proposal.width ?? .infinity
            }
        }()
        var lines: [Line] = []
        var current = Line()

        func flush() {
            guard !current.indices.isEmpty else { return }
            lines.append(current)
            current = Line()
        }

        for index in sizes.indices {
            let size = sizes[index]
            let primary = axis == .vertical ? size.height : size.width
            let cross = axis == .vertical ? size.width : size.height
            let projected = current.primaryExtent + (current.indices.isEmpty ? 0 : spacing) + primary
            if !current.indices.isEmpty, primaryLimit.isFinite, projected > primaryLimit {
                flush()
            }
            current.primaryExtent += (current.indices.isEmpty ? 0 : spacing) + primary
            current.crossExtent = max(current.crossExtent, cross)
            current.indices.append(index)
        }
        flush()
        return lines
    }

    private func boundingSize(of lines: [Line]) -> CGSize {
        let crossTotal = lines.reduce(0) { $0 + $1.crossExtent } + spacing * CGFloat(max(0, lines.count - 1))
        let primaryMax = lines.map(\.primaryExtent).max() ?? 0
        switch axis {
        case .vertical: return CGSize(width: crossTotal, height: primaryMax)
        case .horizontal: return CGSize(width: primaryMax, height: crossTotal)
        }
    }
}
