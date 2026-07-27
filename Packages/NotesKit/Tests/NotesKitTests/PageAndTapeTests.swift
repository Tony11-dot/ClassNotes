import ClassMateTheme
import CoreGraphics
import Foundation
import NotesModels
import NotesServices
import Testing

@Suite("Page sizes and orientation")
struct PageSizeTests {
    @Test("Classic keeps the original 768×1024 ink space forever")
    func classicIsPinned() {
        // Every drawing saved before page sizes existed lives in this space.
        #expect(PageSize.classic.portraitSize == CGSize(width: 768, height: 1024))
        #expect(PageGeometry.size == CGSize(width: 768, height: 1024))
    }

    @Test("Landscape swaps the page's dimensions", arguments: PageSize.allCases)
    func orientationSwaps(size: PageSize) {
        let portrait = size.size(orientation: .portrait)
        let landscape = size.size(orientation: .landscape)
        #expect(portrait.width == landscape.height)
        #expect(portrait.height == landscape.width)
        #expect(portrait.width > 0 && portrait.height > 0)
    }

    @Test("Every raw value round-trips, so a manifest can always be re-read")
    func rawRoundTrip() {
        for size in PageSize.allCases {
            #expect(PageSize(rawValue: size.rawValue) == size)
        }
        for orientation in PageOrientation.allCases {
            #expect(PageOrientation(rawValue: orientation.rawValue) == orientation)
        }
    }

    @Test("A board is offered as a document kind, not as notebook paper")
    func boardIsNotPaper() {
        #expect(!PageSize.notebookChoices.contains(.whiteboard))
        #expect(NotebookKind.whiteboard.isSinglePage)
        #expect(!NotebookKind.notebook.isSinglePage)
    }

    @Test("Line spacing scales monotonically around the classic 32 pt rule")
    func spacingScale() {
        let scales = PageLineSpacing.range.map(PageLineSpacing.scale(steps:))
        #expect(scales == scales.sorted())
        #expect(PageLineSpacing.scale(steps: PageLineSpacing.default) == 1)
        // Out-of-range values clamp rather than producing nonsense geometry.
        #expect(PageLineSpacing.scale(steps: -40) == PageLineSpacing.scale(steps: 1))
        #expect(PageLineSpacing.scale(steps: 900) == PageLineSpacing.scale(steps: 9))
    }
}

@Suite("Templates and covers")
struct TemplateAndCoverTests {
    @Test("Every template belongs to exactly one family, and families cover them all")
    func familiesPartitionTemplates() {
        let grouped = PageTemplate.Family.allCases.flatMap(\.templates)
        #expect(Set(grouped) == Set(PageTemplate.allCases))
        #expect(grouped.count == PageTemplate.allCases.count, "no template is listed twice")
        for template in PageTemplate.allCases {
            #expect(template.family.templates.contains(template))
        }
    }

    @Test("The original six templates keep their raw values")
    func legacyRawValues() {
        // These strings are in every manifest ever written; changing one loses pages.
        #expect(PageTemplate.blank.rawValue == "blank")
        #expect(PageTemplate.ruled.rawValue == "ruled")
        #expect(PageTemplate.dashed.rawValue == "dashed")
        #expect(PageTemplate.dotted.rawValue == "dotted")
        #expect(PageTemplate.grid.rawValue == "grid")
        #expect(PageTemplate.dotGrid.rawValue == "dotGrid")
    }

    @Test("Every template has a name and a symbol")
    func templateMetadata() {
        for template in PageTemplate.allCases {
            #expect(!template.displayName.isEmpty)
            #expect(!template.symbolName.isEmpty)
            #expect(PageTemplate(rawValue: template.rawValue) == template)
        }
    }

    @Test("Every cover design belongs to one category, and categories cover them all")
    func coverCategories() {
        let grouped = CoverDesign.Category.allCases.flatMap(\.designs)
        #expect(Set(grouped) == Set(CoverDesign.allCases))
        #expect(grouped.count == CoverDesign.allCases.count)
        for design in CoverDesign.allCases {
            #expect(!design.displayName.isEmpty)
            #expect(design.category.designs.contains(design))
            #expect(CoverDesign(rawValue: design.rawValue) == design)
        }
    }

    @Test("The default cover is a simple one")
    func defaultCover() {
        #expect(CoverDesign.default == .simple1)
        #expect(CoverDesign.default.category == .simple)
    }

    @Test("Line and cover palettes are valid, unique colors")
    func palettes() {
        for swatch in PaperPalette.lineColors + PaperPalette.coverStocks {
            #expect(!swatch.name.isEmpty)
            #expect(swatch.color.alpha == 1)
            #expect(ThemeColor(hex: swatch.color.hexString) != nil)
        }
        let ids = (PaperPalette.lineColors + PaperPalette.coverStocks).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite("Sticky tape")
struct TapeTests {
    private let pageSize = PageSize.a4.portraitSize

    @Test("A strip's frame encloses the whole path plus its thickness")
    func framePadsForThickness() {
        let path = [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 210)]
        let frame = TapeGeometry.frame(for: path, thickness: 30, in: pageSize)
        #expect(frame.minX < 100)
        #expect(frame.maxX > 300)
        #expect(frame.height >= 30)
        #expect(frame.minY < 200)
    }

    @Test("Frames never leave the page")
    func frameClampsToPage() {
        let path = [CGPoint(x: -50, y: -50), CGPoint(x: pageSize.width + 90, y: pageSize.height + 90)]
        let frame = TapeGeometry.frame(for: path, thickness: 40, in: pageSize)
        #expect(frame.minX >= 0)
        #expect(frame.minY >= 0)
        #expect(frame.maxX <= pageSize.width)
        #expect(frame.maxY <= pageSize.height)
    }

    @Test("A straight strip keeps only its two ends; a rectangle keeps no path")
    func pathPerShape() {
        let drag = (0...20).map { CGPoint(x: Double($0) * 12, y: 40 + Double($0 % 3)) }
        #expect(TapeGeometry.path(for: .line, from: drag) == [drag[0], drag[drag.count - 1]])
        #expect(TapeGeometry.path(for: .rectangle, from: drag).isEmpty)
        let freeform = TapeGeometry.path(for: .draw, from: drag)
        #expect(freeform.count > 2)
        #expect(freeform.count <= drag.count)
    }

    @Test("Thinning drops crowded points but keeps the ends")
    func thinning() {
        // 200 points 1 pt apart — a long slow drag.
        let dense = (0..<200).map { CGPoint(x: Double($0), y: 0) }
        let thinned = TapeGeometry.thin(dense, minimumSpacing: 5)
        #expect(thinned.count < dense.count / 3)
        #expect(thinned.first == dense.first)
        #expect(thinned.last == dense.last)
    }

    @Test("Every pattern has a name and round-trips")
    func patterns() {
        for pattern in TapePattern.allCases {
            #expect(!pattern.displayName.isEmpty)
            #expect(TapePattern(rawValue: pattern.rawValue) == pattern)
        }
        for shape in TapeShape.allCases {
            #expect(!shape.displayName.isEmpty)
            #expect(!shape.symbolName.isEmpty)
            #expect(TapeShape(rawValue: shape.rawValue) == shape)
        }
    }

    @Test("A tape element round-trips through the manifest, lift state included")
    func tapeRoundTrips() throws {
        let tape = PageElement(
            kind: .tape, x: 40, y: 60, width: 220, height: 44,
            tapeShape: .draw, tapePattern: .stripes, colorHex: "#AABBCC",
            points: [PagePoint(x: 4, y: 20), PagePoint(x: 200, y: 24)],
            strokeWidth: 30, isHidden: true
        )
        let manifest = NotebookManifest(pages: [
            PageRecord(template: .ruled, elements: [tape], pageSize: .a4)
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(NotebookManifest.self, from: encoder.encode(manifest))
        let element = try #require(restored.pages.first?.elements.first)
        #expect(element.kind == .tape)
        #expect(element.tapeShape == .draw)
        #expect(element.tapePattern == .stripes)
        #expect(element.colorHex == "#AABBCC")
        #expect(element.points.count == 2)
        #expect(element.strokeWidth == 30)
        #expect(element.isHidden)
    }
}

@Suite("Manifest v6 back-compat")
struct ManifestV6Tests {
    @Test("A v5 page decodes as a classic portrait page with auto rules")
    func decodesV5() throws {
        // Written before sizes, line colors or spacing existed.
        let json = """
        {
          "version": 5,
          "pages": [
            {
              "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
              "template": "ruled",
              "createdAt": "2026-01-01T00:00:00Z",
              "elements": [
                {
                  "id": "2B4E28BA-2FA1-11D2-883F-0016D3CCA427",
                  "kind": "text", "x": 10, "y": 20, "width": 100, "height": 40,
                  "text": "old note", "fontName": "Georgia"
                }
              ],
              "margin": { "position": "leading", "offset": 72 },
              "paperColorHex": "#FBF7EF"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(NotebookManifest.self, from: Data(json.utf8))
        let page = try #require(manifest.pages.first)

        #expect(page.pageSize == .classic)
        #expect(page.orientation == .portrait)
        #expect(page.logicalSize == PageGeometry.size)
        #expect(page.lineColorHex == nil)
        #expect(page.lineSpacingSteps == PageLineSpacing.default)
        #expect(page.paperColorHex == "#FBF7EF")

        // The old text element keeps its content and picks up the legacy size.
        let element = try #require(page.elements.first)
        #expect(element.text == "old note")
        #expect(element.resolvedFontSize == PageElement.legacyTextSize)
        #expect(!element.isBold)
        #expect(element.isHidden == false)
        #expect(element.points.isEmpty)
    }

    @Test("A v6 page round-trips every new field")
    func roundTripsV6() throws {
        let page = PageRecord(
            template: .cornell,
            margin: PageMargin(position: .trailing),
            paperColorHex: "#111111",
            backgroundPayloadFilename: "scan.png",
            pageSize: .letter,
            orientation: .landscape,
            lineColorHex: "#3355AA",
            lineSpacingSteps: 8
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(
            NotebookManifest.self, from: encoder.encode(NotebookManifest(pages: [page]))
        )
        let decoded = try #require(restored.pages.first)
        #expect(restored.version == 6)
        #expect(decoded.template == .cornell)
        #expect(decoded.pageSize == .letter)
        #expect(decoded.orientation == .landscape)
        #expect(decoded.lineColorHex == "#3355AA")
        #expect(decoded.lineSpacingSteps == 8)
        #expect(decoded.backgroundPayloadFilename == "scan.png")
        #expect(decoded.logicalSize == PageSize.letter.size(orientation: .landscape))
    }

    @Test("A page's style is what a new page inherits")
    func styleCarriesEverything() {
        let page = PageRecord(
            template: .graph, margin: PageMargin(position: .none),
            paperColorHex: "#F0F0F0", pageSize: .a5, orientation: .landscape,
            lineColorHex: "#123456", lineSpacingSteps: 3
        )
        let fresh = page.style.makePage()
        #expect(fresh.id != page.id)
        #expect(fresh.template == page.template)
        #expect(fresh.paperColorHex == page.paperColorHex)
        #expect(fresh.lineColorHex == page.lineColorHex)
        #expect(fresh.lineSpacingSteps == page.lineSpacingSteps)
        #expect(fresh.pageSize == page.pageSize)
        #expect(fresh.orientation == page.orientation)
        #expect(fresh.elements.isEmpty)
    }

    @Test("A quick note is plain white A4 with no rules and no margin")
    func quickNoteStyle() {
        let style = PageStyle.quickNote
        #expect(style.template == .blank)
        #expect(style.margin.position == PageMargin.Position.none)
        #expect(style.pageSize == .a4)
        #expect(PaperPalette.isDark(style.paperColorHex) == false)
        #expect(style.paperColorHex == PaperPalette.white.color.hexString)
    }
}

@Suite("Page attachment sync payload")
struct PageAttachmentTests {
    @Test("MIME types are resolved for the formats students actually attach")
    func mimeTypes() {
        #expect(NotebookPageAttachment.mimeType(forExtension: "pdf") == "application/pdf")
        #expect(NotebookPageAttachment.mimeType(forExtension: "PDF") == "application/pdf")
        #expect(NotebookPageAttachment.mimeType(forExtension: "m4a") == "audio/m4a")
        #expect(NotebookPageAttachment.mimeType(forExtension: "png") == "image/png")
        #expect(NotebookPageAttachment.mimeType(forExtension: "wat") == "application/octet-stream")
    }

    @Test("An attachment encodes only the fields its kind uses")
    func encodesPerKind() throws {
        let link = NotebookPageAttachment(kind: "link", name: "Docs", url: "https://example.com")
        let audio = NotebookPageAttachment(
            kind: "audio", name: "Lecture", durationSeconds: 42, dataUrl: "data:audio/m4a;base64,AA=="
        )
        let encoder = JSONEncoder()
        let linkJSON = try #require(
            try JSONSerialization.jsonObject(with: encoder.encode(link)) as? [String: Any]
        )
        #expect(linkJSON["url"] as? String == "https://example.com")
        #expect(linkJSON["dataUrl"] == nil)

        let audioJSON = try #require(
            try JSONSerialization.jsonObject(with: encoder.encode(audio)) as? [String: Any]
        )
        #expect(audioJSON["durationSeconds"] as? Double == 42)
        #expect((audioJSON["dataUrl"] as? String)?.hasPrefix("data:audio/m4a") == true)
    }

    @Test("A page image carries its attachments")
    func pageImageCarriesAttachments() throws {
        let page = NotebookPageImage(
            pageIndex: 2,
            dataUrl: "data:image/png;base64,AA==",
            attachments: [NotebookPageAttachment(kind: "link", name: "x", url: "https://x.test")]
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any]
        )
        #expect(json["pageIndex"] as? Int == 2)
        #expect((json["attachments"] as? [[String: Any]])?.count == 1)
    }

    @Test("The payload cap is big enough for a voice note but bounded")
    func payloadCap() {
        #expect(NotebookPageAttachment.maximumPayloadBytes == 6 * 1024 * 1024)
    }
}
