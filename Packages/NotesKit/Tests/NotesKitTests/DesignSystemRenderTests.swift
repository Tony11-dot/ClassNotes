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
