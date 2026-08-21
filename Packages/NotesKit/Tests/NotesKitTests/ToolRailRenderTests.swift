import ClassMateTheme
import NotesModels
import NotesServices
import SwiftUI
import Testing
@testable import NotesEditor

/// Regression guard for a Build 39 bug: the collapsed rail chip painted
/// nothing at all whenever the pen tray sat alongside the mode buttons in
/// `RailFlowLayout`'s content — see `ToolRailView.penTray`. Renders the real
/// view (every pen preset, every mode button, NOVA/undo/redo all present) and
/// asserts the chip's own pixel is actually painted the theme's accent color,
/// not the page behind it.
@MainActor
@Suite("Tool rail rendering")
struct ToolRailRenderTests {
    @Test("Collapsed chip paints its accent circle, not a blank rail")
    func collapsedChipRenders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-rail-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DocumentStore(rootURL: root)
        let id = UUID()
        try await store.createDocument(id: id, firstPageTemplate: .blank)
        let model = NotebookEditorModel(notebookID: id, store: store)
        await model.load()

        let toolState = ToolState()
        let tracker = ActiveCanvasTracker()
        let services = AppServices(modelContainer: ModelContainerFactory.make(inMemory: true))
        let theme = ThemePreset.light.spec

        let size = CGSize(width: 1024, height: 1366)
        let rail = ZStack {
            theme.surface.color
            ToolRailView(
                toolState: toolState,
                model: model,
                tracker: tracker,
                rulerVisible: .constant(false),
                showPages: .constant(false),
                onPhoto: {}, onFile: {}, onRecord: {}, onBeautifyNow: {}, onNova: {},
                onTapeVisibility: { _ in },
                openPenPanel: nil
            )
        }
        .environment(\.theme, theme)
        .environment(services)
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: rail)
        renderer.scale = 2
        let image = try #require(renderer.uiImage)

        // The chip's default resting spot: `ToolRailView.defaultCenter` —
        // `edgeInset (30) + chipSize/2 (28)` in from the left edge, vertically
        // centered. Offset from the exact center so the sample lands on the
        // circle's fill rather than a white stroke of the icon glyph drawn
        // on top of it.
        let chipPoint = CGPoint(x: 58 + 18, y: size.height / 2 + 18)
        let pixel = try #require(image.pixel(at: chipPoint, canvasSize: size))

        let accent = theme.accent
        let tolerance = 0.08
        #expect(abs(pixel.red - accent.red) < tolerance, "chip pixel isn't the accent color — rail is blank")
        #expect(abs(pixel.green - accent.green) < tolerance, "chip pixel isn't the accent color — rail is blank")
        #expect(abs(pixel.blue - accent.blue) < tolerance, "chip pixel isn't the accent color — rail is blank")
    }
}

private extension UIImage {
    struct RailPixel {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Samples one point (in the SwiftUI view's own point space) from an
    /// image rendered at `canvasSize` points, whatever the image's own pixel
    /// scale turns out to be.
    func pixel(at point: CGPoint, canvasSize: CGSize) -> RailPixel? {
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
        let scaleX = CGFloat(cgImage.width) / canvasSize.width
        let scaleY = CGFloat(cgImage.height) / canvasSize.height
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        context.draw(
            cgImage,
            in: CGRect(
                x: -point.x * scaleX + 0.5, y: -point.y * scaleY + 0.5,
                width: width, height: height
            )
        )
        return RailPixel(
            red: Double(data[0]) / 255.0,
            green: Double(data[1]) / 255.0,
            blue: Double(data[2]) / 255.0
        )
    }
}
