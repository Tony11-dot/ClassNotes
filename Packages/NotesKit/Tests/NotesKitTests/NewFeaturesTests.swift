import ClassMateTheme
import Foundation
import NotesModels
import Testing

@Suite("Paper palette")
struct PaperPaletteTests {
    @Test("Palette is non-empty and every swatch has a valid opaque color")
    func swatchesValid() {
        #expect(!PaperPalette.all.isEmpty)
        for swatch in PaperPalette.all {
            #expect(!swatch.name.isEmpty)
            #expect(swatch.color.alpha == 1)
            // Round-trips through hex (the value the manifest stores).
            #expect(ThemeColor(hex: swatch.color.hexString) != nil)
        }
    }

    @Test("Swatch ids are unique")
    func uniqueIDs() {
        let ids = PaperPalette.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("isDark distinguishes dark stocks from light paper")
    func darkness() {
        #expect(PaperPalette.isDark("#121214") == true)   // black
        #expect(PaperPalette.isDark("#16241E") == true)   // chalkboard
        #expect(PaperPalette.isDark("#FFFFFF") == false)  // white
        #expect(PaperPalette.isDark("#F6ECD6") == false)  // cream
        #expect(PaperPalette.isDark(nil) == false)        // auto
    }
}

@Suite("Page template line styles")
struct PageTemplateStyleTests {
    @Test("Dashed and dotted are part of the ruled family; grid/dotGrid are not")
    func ruledFamily() {
        #expect(PageTemplate.ruled.isRuledFamily)
        #expect(PageTemplate.dashed.isRuledFamily)
        #expect(PageTemplate.dotted.isRuledFamily)
        #expect(!PageTemplate.grid.isRuledFamily)
        #expect(!PageTemplate.dotGrid.isRuledFamily)
        #expect(!PageTemplate.blank.isRuledFamily)
    }

    @Test("Every template raw value round-trips")
    func rawRoundTrip() {
        for template in PageTemplate.allCases {
            #expect(PageTemplate(rawValue: template.rawValue) == template)
        }
    }
}

@Suite("Manifest v5 back-compat")
struct ManifestBackCompatTests {
    @Test("A pre-v5 page (no background key) decodes with a nil background")
    func decodesOldManifest() throws {
        // A v4-style page: has paperColorHex but NO backgroundPayloadFilename.
        let json = """
        {
          "version": 4,
          "pages": [
            {
              "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
              "template": "ruled",
              "createdAt": "2026-01-01T00:00:00Z",
              "elements": [],
              "margin": { "position": "leading", "offset": 72 },
              "paperColorHex": "#FBF7EF"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(NotebookManifest.self, from: Data(json.utf8))
        #expect(manifest.pages.count == 1)
        #expect(manifest.pages[0].paperColorHex == "#FBF7EF")
        #expect(manifest.pages[0].backgroundPayloadFilename == nil)
    }

    @Test("A page with a PDF background round-trips")
    func backgroundRoundTrips() throws {
        let page = PageRecord(
            template: .blank,
            margin: PageMargin(position: .none),
            backgroundPayloadFilename: "abc.png"
        )
        let manifest = NotebookManifest(pages: [page])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            NotebookManifest.self, from: encoder.encode(manifest)
        )
        #expect(restored.version == NotebookManifest.currentVersion)
        #expect(restored.pages[0].backgroundPayloadFilename == "abc.png")
        #expect(restored.pages[0].margin.position == .none)
    }
}
