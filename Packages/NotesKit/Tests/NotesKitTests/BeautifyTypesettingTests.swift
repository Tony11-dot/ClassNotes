import CoreGraphics
import Foundation
import NotesModels
import PencilKit
import Testing
import UIKit
@testable import NotesDesignSystem
@testable import NotesEditor

/// Getting the CHOSEN face on the page, at the CHOSEN size.
///
/// `Font.custom` and `UIFont(name:)` fail silently: ask for a face iOS won't hand
/// over by name and you get the system font, no error. That is what made the
/// beautification font picker look decorative — every setting produced the same
/// type.
@Suite("Font resolution")
struct FontResolverTests {

    @Test("Every face in the catalog resolves to the face it names")
    func catalogResolves() {
        for font in FontLibrary.all {
            #expect(
                FontResolver.resolves(font.fontName),
                "\(font.displayName) (\(font.fontName)) falls back to the system font"
            )
        }
    }

    @Test("Apple's system-design faces resolve through a descriptor, not a name")
    func systemDesignFaces() {
        // These two are the reason this layer exists: they are real, offered in the
        // picker, and unreachable by PostScript name.
        let rounded = FontResolver.uiFont(named: "SFRounded-Regular", size: 24)
        #expect(rounded.familyName.localizedCaseInsensitiveContains("rounded"))
        let serif = FontResolver.uiFont(named: "NewYork-Regular", size: 24)
        #expect(serif.familyName != UIFont.systemFont(ofSize: 24).familyName)
    }

    @Test("A real bundled face is returned at the size asked for")
    func honoursTheSize() {
        let font = FontResolver.uiFont(named: "Georgia", size: 31)
        #expect(font.familyName == "Georgia")
        #expect(font.pointSize == 31)
        #expect(FontResolver.uiFont(named: "Georgia", size: 31, bold: true)
            .fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test("A name iOS has never heard of degrades to the system face, not a crash")
    func unknownName() {
        let font = FontResolver.uiFont(named: "NotAFont-Ever", size: 18)
        #expect(font.pointSize == 18)
        #expect(!FontResolver.resolves("NotAFont-Ever"))
    }

    @Test("Measurement grows with the text and with the size")
    func measurement() {
        let short = FontResolver.measureWidth("hi", name: "Georgia", size: 20)
        let long = FontResolver.measureWidth("hi there everyone", name: "Georgia", size: 20)
        let bigger = FontResolver.measureWidth("hi", name: "Georgia", size: 40)
        #expect(long > short)
        #expect(bigger > short)
        #expect(FontResolver.measureWidth("", name: "Georgia", size: 20) == 0)
        #expect(FontResolver.lineHeight(name: "Georgia", size: 40)
            > FontResolver.lineHeight(name: "Georgia", size: 20))
    }
}

/// The settings the beautification panel offers reaching the page.
@MainActor
@Suite("Beautification honours its settings")
struct BeautifySettingsApplicationTests {
    private let pageSize = CGSize(width: 768, height: 1024)

    private func line(_ text: String, at rect: CGRect) -> RecognizedLine {
        RecognizedLine(text: text, bounds: rect, strokeIndices: [0], meanForce: 0.2)
    }

    @Test("The typeset run carries the chosen size AND the chosen line spacing")
    func runCarriesTheSettings() throws {
        let settings = BeautifySettings(
            isEnabled: true, unifySizeAndSpacing: true, fontSize: 31, lineSpacing: 1.9
        )
        let plan = LiveBeautifier.plan(
            lines: [line("hello", at: CGRect(x: 60, y: 200, width: 160, height: 30))],
            existing: [], settings: settings, fontName: "Georgia",
            colorHex: nil, pageSize: pageSize,
            metrics: LiveBeautifier.metrics(fontName: "Georgia")
        )
        let element = try #require(plan.inserts.first)
        #expect(element.resolvedFontSize == 31)
        // Spacing used to stop at the layout: the run was SIZED for 1.9 and DRAWN
        // at 1.0, so the words sat in the top third of a box three lines tall.
        #expect(element.resolvedLineSpacing == 1.9)
        #expect(abs(element.extraLeading - 31 * 0.9) < 0.01)
    }

    @Test("The box is measured in the real face, so nothing is clipped")
    func boxFitsTheType() throws {
        let fontName = "Georgia"
        let text = "the quick brown fox jumps over the lazy dog"
        let settings = BeautifySettings(isEnabled: true, unifySizeAndSpacing: true, fontSize: 24)
        let plan = LiveBeautifier.plan(
            lines: [line(text, at: CGRect(x: 40, y: 300, width: 300, height: 28))],
            existing: [], settings: settings, fontName: fontName,
            colorHex: nil, pageSize: pageSize,
            metrics: LiveBeautifier.metrics(fontName: fontName)
        )
        let element = try #require(plan.inserts.first)
        let measured = FontResolver.measureWidth(text, name: fontName, size: 24)
        let drawable = element.width - BeautifyLayout.textInset * 2
        let lines = ceil(Double(measured) / drawable)
        let lineHeight = Double(FontResolver.lineHeight(name: fontName, size: 24))
        #expect(element.height >= lines * lineHeight, "every wrapped line has room")
        #expect(element.x + element.width <= pageSize.width + 0.01)
    }

    @Test("With unify off the spacing slider stays out of it")
    func unifyOffTracksTheWriting() throws {
        var settings = BeautifySettings(isEnabled: true, unifySizeAndSpacing: false)
        settings.lineSpacing = 2.4
        #expect(settings.effectiveLineSpacing == 1)

        let plan = LiveBeautifier.plan(
            lines: [line("tracks the ink", at: CGRect(x: 40, y: 100, width: 200, height: 44))],
            existing: [], settings: settings, fontName: "Georgia",
            colorHex: nil, pageSize: pageSize, metrics: .nominal
        )
        let element = try #require(plan.inserts.first)
        #expect(element.resolvedLineSpacing == 1)
        #expect(element.resolvedFontSize > 24, "the size follows the handwriting instead")
    }

    @Test("A run's line spacing survives a trip through the manifest")
    func spacingRoundTrips() throws {
        let element = PageElement(
            kind: .text, x: 0, y: 0, width: 200, height: 60,
            text: "spaced", fontName: "Georgia", fontSize: 26, lineSpacing: 1.7
        )
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(PageElement.self, from: encoder.encode(element))
        #expect(decoded.lineSpacing == 1.7)
        // An older element simply has none, and draws single-spaced.
        let legacy = PageElement(kind: .text, x: 0, y: 0, width: 10, height: 10, text: "old")
        #expect(legacy.resolvedLineSpacing == 1)
        #expect(legacy.extraLeading == 0)
    }
}

/// Making Vision's job easier, since "detection is weak" is mostly a question of
/// what we hand it.
@MainActor
@Suite("Handwriting detection")
struct HandwritingDetectionTests {

    private func stroke(width: CGFloat) -> PKStroke {
        let points = (0...30).map { index in
            PKStrokePoint(
                location: CGPoint(x: Double(index) * 5, y: 20),
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: width, height: width),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        )
    }

    @Test("Hairline ink is thickened for recognition, thick ink is left alone")
    func thickening() {
        let hairline = stroke(width: 0.6)
        let widened = LiveBeautifier.thickened(hairline.path, to: 3)
        #expect(widened.allSatisfy { $0.size.width >= 3 })
        #expect(widened.count == hairline.path.count, "the geometry is untouched")
        #expect(Array(widened).map(\.location) == Array(hairline.path).map(\.location))

        // Already fat enough: the very same path back, no rebuild.
        let fat = stroke(width: 8)
        #expect(Array(LiveBeautifier.thickened(fat.path, to: 3)).map(\.size) ==
                Array(fat.path).map(\.size))
        // No floor asked for, nothing done.
        #expect(Array(LiveBeautifier.thickened(hairline.path, to: 0)).map(\.size) ==
                Array(hairline.path).map(\.size))
    }

    @Test("Ink that reads as nothing is retried much larger before giving up")
    func retriesAtALargerScale() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 14)
        let region = small.insetBy(dx: -12, dy: -12)
        let scales = LiveBeautifier.renderScales(for: small, in: region)
        #expect(scales.count == 2, "one attempt is a coin toss on cramped writing")
        #expect(scales[1] > scales[0])
        #expect(scales[0] == LiveBeautifier.renderScale(for: small, in: region),
                "the sweet spot goes first")
        #expect(scales.allSatisfy { $0 <= 14 })
    }

    @Test("A whole page of writing is never rendered into an enormous crop")
    func cropStaysBounded() {
        // Tiny writing over a full page: the ideal per-line scale would blow the
        // crop up past anything Vision can chew through.
        let content = CGRect(x: 0, y: 0, width: 760, height: 1000)
        let region = CGRect(x: 0, y: 0, width: 768, height: 1024)
        let scale = LiveBeautifier.renderScale(for: content, in: region)
        #expect(max(region.width, region.height) * scale <= LiveBeautifier.maximumCropSide + 1)
        #expect(scale >= 1, "and never shrunk below its own size")
    }

    @Test("The recognition ink floor scales with the writing")
    func inkFloor() {
        let small = LiveBeautifier.recognitionInkWidth(
            for: [CGRect(x: 0, y: 0, width: 100, height: 12)]
        )
        let large = LiveBeautifier.recognitionInkWidth(
            for: [CGRect(x: 0, y: 0, width: 400, height: 90)]
        )
        #expect(small >= 1.6, "a fineliner still has to survive rasterization")
        #expect(large > small, "and big writing isn't turned into a solid blob")
    }

    // MARK: - Whole-region recognition

    @Test("A Vision box maps back onto the page it was cropped from")
    func visionBoxMapsToPage() {
        let region = CGRect(x: 100, y: 200, width: 400, height: 300)
        // Vision's origin is bottom-left: the TOP half of the crop is maxY 1.
        let top = LiveBeautifier.pageRect(
            forVisionBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), in: region
        )
        #expect(top.minY == 200, "the top of the box is the top of the region")
        #expect(top.height == 150)
        #expect(top.minX == 100)
        #expect(top.width == 400)
    }

    @Test("A recognized line claims the ink under it, and only once")
    func linesClaimTheirOwnStrokes() {
        // Two lines of two strokes each, one above the other.
        let boxes = [
            CGRect(x: 10, y: 10, width: 30, height: 20),
            CGRect(x: 50, y: 12, width: 30, height: 18),
            CGRect(x: 10, y: 60, width: 30, height: 20),
            CGRect(x: 50, y: 62, width: 30, height: 18)
        ]
        let first = LiveBeautifier.strokes(
            boxes, inside: CGRect(x: 8, y: 10, width: 80, height: 20), excluding: []
        )
        #expect(first == [0, 1])
        let second = LiveBeautifier.strokes(
            boxes, inside: CGRect(x: 8, y: 60, width: 80, height: 20),
            excluding: Set(first)
        )
        #expect(second == [2, 3], "the second line takes the ink the first didn't")
    }

    @Test("One short word is read, not thrown away for being narrow")
    func aSingleWordSurvives() {
        // The old pass required a line's box to be wider than it was tall, so a
        // single word — the commonest thing anybody writes — never reached Vision.
        let word = CGRect(x: 20, y: 20, width: 26, height: 30)
        let matched = LiveBeautifier.strokes(
            [word], inside: CGRect(x: 18, y: 22, width: 30, height: 22), excluding: []
        )
        #expect(matched == [0])
    }
}
