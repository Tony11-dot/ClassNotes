import ClassMateTheme
import NotesModels
import SwiftUI
import Testing
@testable import NotesDesignSystem

/// Render tests across ALL themes: every DesignSystem component must produce
/// a deterministic image under every preset, and the paper the user writes on
/// must actually be the theme's paper color.
@MainActor
@Suite("DesignSystem rendering across all themes")
struct DesignSystemRenderTests {
    private func render(_ view: some View, size: CGSize = CGSize(width: 200, height: 264)) -> UIImage? {
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height)
        )
        renderer.scale = 2
        return renderer.uiImage
    }

    @Test("Page templates render under every preset", arguments: ThemePreset.allCases)
    func templates(preset: ThemePreset) {
        for template in PageTemplate.allCases {
            let view = PageTemplateView(template: template)
                .environment(\.theme, preset.spec)
                .environment(\.paperTone, PaperTone.neutral)
            #expect(render(view) != nil, "\(preset.rawValue)/\(template.rawValue) failed to render")
        }
    }

    @Test("Template rendering is deterministic (stable snapshot)", arguments: ThemePreset.allCases)
    func templateDeterminism(preset: ThemePreset) throws {
        let view = PageTemplateView(template: .ruled)
            .environment(\.theme, preset.spec)
            .environment(\.paperTone, PaperTone.neutral)
        let first = try #require(render(view)?.pngData())
        let second = try #require(render(view)?.pngData())
        #expect(first == second)
    }

    @Test("Blank paper pixel matches the theme's paper token", arguments: ThemePreset.allCases)
    func paperPixel(preset: ThemePreset) throws {
        let spec = preset.spec
        let view = PageTemplateView(template: .blank)
            .environment(\.theme, spec)
            .environment(\.paperTone, PaperTone.neutral)
        let image = try #require(render(view))
        let pixel = try #require(image.centerPixel())

        let tolerance = 2.0 / 255.0
        #expect(abs(pixel.red - spec.paper.red) <= tolerance, "\(preset.rawValue) paper red drifted")
        #expect(abs(pixel.green - spec.paper.green) <= tolerance, "\(preset.rawValue) paper green drifted")
        #expect(abs(pixel.blue - spec.paper.blue) <= tolerance, "\(preset.rawValue) paper blue drifted")
    }

    @Test("Covers, swatches and empty states render under every preset", arguments: ThemePreset.allCases)
    func components(preset: ThemePreset) {
        let spec = preset.spec
        let cover = NotebookCoverView(title: "Physics", coverColor: spec.coverPalette[0])
            .environment(\.theme, spec)
        #expect(render(cover) != nil)

        let swatch = ThemeSwatchView(spec: spec)
        #expect(render(swatch, size: CGSize(width: 120, height: 52)) != nil)

        let empty = EmptyStateView(
            systemImage: "book.closed",
            title: "No notebooks yet",
            message: "Create one to get started."
        )
        .environment(\.theme, spec)
        #expect(render(empty, size: CGSize(width: 320, height: 240)) != nil)
    }

    // MARK: - Milestone 2 surfaces

    @Test("Every cover design renders under every preset", arguments: ThemePreset.allCases)
    func coverDesigns(preset: ThemePreset) {
        let spec = preset.spec
        for design in CoverDesign.allCases {
            let cover = NotebookCoverView(
                title: "Biology", coverColor: spec.coverPalette[0], design: design
            )
            .environment(\.theme, spec)
            #expect(
                render(cover, size: CGSize(width: 150, height: 200)) != nil,
                "\(preset.rawValue)/\(design.rawValue) failed to render"
            )
        }
    }

    @Test("Cover art is deterministic, so covers never shimmer between redraws")
    func coverDeterminism() throws {
        let spec = ThemePreset.matcha.spec
        for design in [CoverDesign.confetti, .marble, .terrazzo, .stars, .kraft, .composition] {
            let view = NotebookCoverView(title: "X", coverColor: spec.coverPalette[1], design: design)
                .environment(\.theme, spec)
            let first = try #require(render(view, size: CGSize(width: 120, height: 160))?.pngData())
            let second = try #require(render(view, size: CGSize(width: 120, height: 160))?.pngData())
            #expect(first == second, "\(design.rawValue) is not deterministic")
        }
    }

    @Test("Every template renders at every paper size and direction", arguments: ThemePreset.allCases)
    func templatesAtEverySize(preset: ThemePreset) {
        let spec = preset.spec
        for template in PageTemplate.allCases {
            for size in [PageSize.a4, .classic, .whiteboard] {
                for orientation in PageOrientation.allCases {
                    let style = PageStyle(
                        template: template, pageSize: size, orientation: orientation
                    )
                    let view = PageTemplateView(style: style)
                        .environment(\.theme, spec)
                        .environment(\.paperTone, PaperTone.neutral)
                    #expect(
                        render(view) != nil,
                        "\(preset.rawValue)/\(template.rawValue)/\(size.rawValue)/\(orientation.rawValue) failed"
                    )
                }
            }
        }
    }

    @Test("A chosen line colour and spacing render on every template", arguments: ThemePreset.allCases)
    func lineColorAndSpacing(preset: ThemePreset) {
        let spec = preset.spec
        for steps in PageLineSpacing.range {
            let style = PageStyle(
                template: .ruled, paperColorHex: PaperPalette.white.color.hexString,
                lineColorHex: PaperPalette.lineColors[0].color.hexString, lineSpacingSteps: steps
            )
            let view = PageTemplateView(style: style)
                .environment(\.theme, spec)
                .environment(\.paperTone, PaperTone.neutral)
            #expect(render(view) != nil, "\(preset.rawValue) spacing \(steps) failed to render")
        }
    }

    @Test("Tape renders in every pattern, shape and lift state", arguments: ThemePreset.allCases)
    func tape(preset: ThemePreset) {
        let spec = preset.spec
        let path = (0...12).map { CGPoint(x: Double($0) * 12, y: 20 + Double($0 % 3) * 4) }
        for pattern in TapePattern.allCases {
            for shape in TapeShape.allCases {
                for lifted in [true, false] {
                    let view = TapeView(
                        shape: shape, pattern: pattern, color: spec.accentMuted,
                        points: path, thickness: 30, isLifted: lifted
                    )
                    .environment(\.theme, spec)
                    #expect(
                        render(view, size: CGSize(width: 160, height: 60)) != nil,
                        "\(preset.rawValue)/\(pattern.rawValue)/\(shape.rawValue) failed"
                    )
                }
            }
        }
    }

    @Test("The pen tray and stroke preview render under every preset", arguments: ThemePreset.allCases)
    func penTray(preset: ThemePreset) {
        let spec = preset.spec
        for pen in PenLibrary.all {
            let glyph = PenGlyphView(preset: pen, color: spec.ink, isSelected: pen.id == "flow")
                .environment(\.theme, spec)
            #expect(
                render(glyph, size: CGSize(width: 46, height: 20)) != nil,
                "\(preset.rawValue)/\(pen.id) failed to render"
            )
            let preview = StrokePreview(
                color: spec.ink, width: pen.defaults.effectiveWidth,
                opacity: pen.defaults.concentration, stability: pen.defaults.stability
            )
            .environment(\.theme, spec)
            #expect(render(preview, size: CGSize(width: 240, height: 92)) != nil)
        }
    }

    @Test("No two pens in the tray look alike")
    func penGlyphsAreDistinct() throws {
        // The tray has to say which pen is in your hand without opening its panel,
        // so every preset needs its own silhouette — not just its own colour. Same
        // ink, same size, same theme: only the shape can differ.
        let spec = ThemePreset.allCases[0].spec
        var seen: [String: Data] = [:]
        for pen in PenLibrary.all {
            let glyph = PenGlyphView(preset: pen, color: spec.ink, isSelected: false)
                .environment(\.theme, spec)
            let image = try #require(
                render(glyph, size: CGSize(width: 64, height: 26)),
                "\(pen.id) failed to render"
            )
            let png = try #require(image.pngData())
            if let twin = seen.first(where: { $0.value == png })?.key {
                Issue.record("\(pen.id) is drawn identically to \(twin)")
            }
            seen[pen.id] = png
        }
        #expect(seen.count == PenLibrary.all.count)
    }

    @Test("Page content — text, tape, links and chips — renders under every preset",
          arguments: ThemePreset.allCases)
    func pageContent(preset: ThemePreset) {
        let spec = preset.spec
        let elements: [PageElement] = [
            PageElement(
                kind: .text, x: 20, y: 20, width: 200, height: 40,
                text: "hi my name is tony", fontName: "Georgia", fontSize: 23, isBold: true
            ),
            PageElement(
                kind: .link, x: 20, y: 80, width: 200, height: 50,
                displayName: "Revision guide", urlString: "https://example.com"
            ),
            PageElement(
                kind: .file, x: 20, y: 140, width: 200, height: 50, displayName: "worksheet.pdf"
            ),
            PageElement(
                kind: .tape, x: 20, y: 200, width: 200, height: 40,
                tapeShape: .rectangle, tapePattern: .stripes,
                colorHex: spec.accentMuted.hexString, strokeWidth: 30
            )
        ]
        let view = PageContentView(
            elements: elements,
            displaySize: CGSize(width: 260, height: 320),
            logicalSize: CGSize(width: 260, height: 320),
            mediaURL: { URL(fileURLWithPath: "/dev/null/\($0)") }
        )
        .environment(\.theme, spec)
        #expect(render(view, size: CGSize(width: 260, height: 320)) != nil)
    }

    @Test("The colour wheel renders under every preset", arguments: ThemePreset.allCases)
    func colorWheel(preset: ThemePreset) {
        let spec = preset.spec
        let view = ColorWheelPicker(color: .constant(spec.accent), showsOpacity: true)
            .environment(\.theme, spec)
        #expect(render(view, size: CGSize(width: 250, height: 420)) != nil)
    }

    @Test("HSB conversion round-trips every palette colour")
    func hsbRoundTrip() {
        for preset in ThemePreset.allCases {
            for color in preset.spec.coverPalette + [preset.spec.ink, preset.spec.paper] {
                let hsb = color.hsb
                let rebuilt = ThemeColor(
                    hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness
                )
                let tolerance = 0.01
                #expect(abs(rebuilt.red - color.red) < tolerance, "\(color.hexString) red drifted")
                #expect(abs(rebuilt.green - color.green) < tolerance, "\(color.hexString) green drifted")
                #expect(abs(rebuilt.blue - color.blue) < tolerance, "\(color.hexString) blue drifted")
            }
        }
    }
}

extension UIImage {
    struct Pixel {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Samples the center pixel in sRGB by redrawing into a known-format
    /// 1×1 bitmap context.
    func centerPixel() -> Pixel? {
        guard let cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &data,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        context.draw(
            cgImage,
            in: CGRect(x: -width / 2 + 0.5, y: -height / 2 + 0.5, width: width, height: height)
        )
        return Pixel(
            red: Double(data[0]) / 255.0,
            green: Double(data[1]) / 255.0,
            blue: Double(data[2]) / 255.0
        )
    }
}
