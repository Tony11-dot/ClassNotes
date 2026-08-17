import ClassMateTheme
import NotesModels
import QuickLook
import SwiftUI
import UIKit

/// Read-only rendering of a page's non-ink content: images, typeset text, voice
/// notes you can play, files you can open, links you can follow, and tape you can
/// lift.
///
/// The editor has its own interactive layer; this is the shared, non-editing one,
/// used by the iPhone viewer and any other place a page is displayed rather than
/// written on. It lives in the design system so no viewer has to reach into
/// `NotesEditor`.
public struct PageContentView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    let elements: [PageElement]
    /// Displayed page size in view points.
    let displaySize: CGSize
    /// The page's logical size, for scaling.
    let logicalSize: CGSize
    /// Resolves a payload filename to a file on disk.
    let mediaURL: (String) -> URL
    /// Called when a strip of tape is tapped, if the host wants to persist the
    /// lift. When nil, tape is lifted only for as long as the page is on screen.
    var onToggleTape: ((UUID) -> Void)?
    /// Which elements this instance renders, relative to the ink layer the
    /// caller composites around it. See `layer`'s doc for why.
    var layer: Layer = .all

    /// Ink paints ABOVE non-tape elements so a stroke drawn over an image or a
    /// file is actually visible on top of it — the same split
    /// `NotesEditor.PageElementsLayer` uses. Tape stays above ink, since
    /// hiding what's underneath it is the entire point of tape. A caller that
    /// composites ink as its own separate layer (`PageCompositeView`,
    /// `NotebookViewerScreen`) renders one `PageContentView` on each side of
    /// it; `.all` (the default) is for a caller with no ink layer to split
    /// around at all.
    public enum Layer: Sendable {
        case all, belowInk, aboveInk
    }

    @State private var locallyLifted: Set<UUID> = []
    @State private var previewURL: URL?

    public init(
        elements: [PageElement],
        displaySize: CGSize,
        logicalSize: CGSize,
        mediaURL: @escaping (String) -> URL,
        onToggleTape: ((UUID) -> Void)? = nil,
        layer: Layer = .all
    ) {
        self.elements = elements
        self.displaySize = displaySize
        self.logicalSize = logicalSize
        self.mediaURL = mediaURL
        self.onToggleTape = onToggleTape
        self.layer = layer
    }

    private var scale: CGFloat { displaySize.width / max(logicalSize.width, 1) }

    /// Fills read as being under the ink (their polygon already stops exactly
    /// where the flood stopped, at the ink's own contour) regardless of which
    /// pass draws them, so they travel with the non-tape elements.
    private var fillElements: [PageElement] {
        layer == .aboveInk ? [] : elements.filter { $0.kind == .fill }
    }

    private var otherElements: [PageElement] {
        let nonFill = elements.filter { $0.kind != .fill }
        switch layer {
        case .all: return nonFill
        case .belowInk: return nonFill.filter { $0.kind != .tape }
        case .aboveInk: return nonFill.filter { $0.kind == .tape }
        }
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Fills first and whole-page: their outlines are in absolute page
            // coordinates, so putting one inside a frame at its own box offsets
            // the colour by that box a second time and it lands nowhere near the
            // shape it was flooded out of.
            ForEach(fillElements) { element in
                FillRegionView(
                    points: element.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                    color: element.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accentMuted
                )
                .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
            }
            ForEach(otherElements) { element in
                view(for: element)
                    .frame(width: element.width * scale, height: element.height * scale)
                    .rotationEffect(.degrees(element.rotation))
                    .position(
                        x: (element.x + element.width / 2) * scale,
                        y: (element.y + element.height / 2) * scale
                    )
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private func view(for element: PageElement) -> some View {
        switch element.kind {
        case .fill:
            // Drawn whole-page above; never reached.
            Color.clear
        case .image:
            imageView(element)
        case .text:
            Text(element.text ?? "")
                .font(font(for: element))
                .lineSpacing(element.extraLeading * scale)
                .foregroundStyle((element.textColorHex.flatMap(ThemeColor.init(hex:)) ?? theme.ink).color)
                .padding(6 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .codeBlock:
            codeBlockView(element)
        case .unknown:
            // A kind this build doesn't recognise — nothing to draw, but the
            // page's other elements still render.
            Color.clear
        case .audio:
            if let filename = element.payloadFilename {
                VoiceBubbleView(
                    url: mediaURL(filename),
                    duration: element.durationSeconds ?? 0,
                    seed: element.id.hashValue
                )
            }
        case .file:
            Button {
                if let filename = element.payloadFilename { previewURL = mediaURL(filename) }
            } label: {
                chip(systemImage: "doc.fill", title: element.displayName ?? "File")
            }
            .buttonStyle(.plain)
        case .link:
            Button {
                if let string = element.urlString, let url = URL(string: string) { openURL(url) }
            } label: {
                chip(systemImage: "link", title: element.displayName ?? element.urlString ?? "Link")
            }
            .buttonStyle(.plain)
        case .tape:
            let lifted = element.isHidden || locallyLifted.contains(element.id)
            TapeView(
                shape: element.tapeShape ?? .rectangle,
                pattern: element.tapePattern ?? .solid,
                color: element.colorHex.flatMap(ThemeColor.init(hex:)) ?? theme.accentMuted,
                points: element.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                thickness: (element.strokeWidth ?? TapeGeometry.defaultThickness) * scale,
                isLifted: lifted
            )
            .onTapGesture {
                if let onToggleTape {
                    onToggleTape(element.id)
                } else if locallyLifted.contains(element.id) {
                    locallyLifted.remove(element.id)
                } else {
                    locallyLifted.insert(element.id)
                }
            }
        }
    }

    @ViewBuilder
    private func imageView(_ element: PageElement) -> some View {
        if let filename = element.payloadFilename,
           let data = try? Data(contentsOf: mediaURL(filename)),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.separator.color, lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceRaised.color)
                .overlay(Image(systemName: "photo").foregroundStyle(theme.inkSecondary.color))
        }
    }

    /// Read-only render of a code block — same styling rule as the editor's:
    /// the element's own colours/radius when set, the code-block defaults
    /// otherwise. No syntax highlighting is derived from `codeLanguage`; it's
    /// a display label only.
    private func codeBlockView(_ element: PageElement) -> some View {
        let radius = (element.codeCornerRadius ?? 10) * scale
        let background = ThemeColor(hex: element.colorHex ?? CodeBlockSettings.defaultBackgroundHex)
            ?? theme.surfaceRaised
        let foreground = ThemeColor(hex: element.textColorHex ?? CodeBlockSettings.defaultTextHex)
            ?? theme.ink
        return Text(element.text ?? "")
            .font(font(for: element))
            .lineSpacing(element.extraLeading * scale)
            .foregroundStyle(foreground.color)
            .padding(10 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.separator.color, lineWidth: 0.5)
            )
    }

    private func font(for element: PageElement) -> Font {
        FontResolver.font(
            named: element.fontName,
            size: element.resolvedFontSize * scale,
            bold: element.isBold
        )
    }

    private func chip(systemImage: String, title: String) -> some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: systemImage).foregroundStyle(theme.accent.color)
            Text(title)
                .font(.dsSystem(size: 15 * scale, weight: .medium))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 12 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
    }
}
