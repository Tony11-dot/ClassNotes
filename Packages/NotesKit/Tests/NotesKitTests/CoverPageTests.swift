import ClassMateTheme
import Foundation
import NotesModels
import Testing
@testable import NotesServices

/// The cover as page one: it's created with the notebook, notebooks made before
/// covers were pages get one exactly once, it survives a round trip through the
/// manifest, and the rendered cover is stored where every surface can read it.
@Suite("Cover pages")
struct CoverPageTests {
    private func makeStore() -> (DocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-cover-\(UUID().uuidString)", isDirectory: true)
        return (DocumentStore(rootURL: root), root)
    }

    @Test("A notebook with a cover gets it as page one, ahead of its paper")
    func createsCoverPage() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let style = PageStyle(template: .ruled, pageSize: .a4, orientation: .portrait)

        let manifest = try await store.createDocument(
            id: id, style: style, pageCount: 2, includesCover: true
        )

        #expect(manifest.pages.count == 3)
        #expect(manifest.pages[0].isCover)
        #expect(!manifest.pages[1].isCover)
        #expect(!manifest.pages[2].isCover)
        #expect(manifest.coverPage?.id == manifest.pages[0].id)
        // The cover keeps the notebook's geometry, so the page scroll stays even.
        #expect(manifest.pages[0].logicalSize == manifest.pages[1].logicalSize)
        // Nothing is printed under the cover artwork.
        #expect(manifest.pages[0].template == .blank)
        #expect(manifest.pages[0].margin.position == .none)
    }

    @Test("Without a cover, page one is paper")
    func createsWithoutCover() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()

        let manifest = try await store.createDocument(
            id: id, style: PageStyle(template: .grid), pageCount: 1
        )

        #expect(manifest.pages.count == 1)
        #expect(!manifest.hasCoverPage)
        #expect(manifest.coverPage == nil)
    }

    @Test("A pre-v7 notebook gains its cover once — and a deleted cover stays gone")
    func migratesOldNotebookOnce() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        // A notebook exactly as an older build left it: two pages, no cover, and a
        // manifest stamped with the version of the day.
        let old = NotebookManifest(version: 6, pages: [
            PageRecord(template: .ruled), PageRecord(template: .ruled),
        ])
        try FileManager.default.createDirectory(
            at: store.documentURL(for: id), withIntermediateDirectories: true
        )
        try await store.writeManifest(old, for: id)

        let migrated = try await store.ensureCoverPage(notebook: id, style: PageStyle())
        #expect(migrated.pages.count == 3)
        #expect(migrated.pages[0].isCover)
        #expect(migrated.version == NotebookManifest.currentVersion)

        // Re-opening doesn't add a second cover.
        let again = try await store.ensureCoverPage(notebook: id, style: PageStyle())
        #expect(again.pages.count == 3)
        #expect(again.pages.filter(\.isCover).count == 1)

        // And a cover the user deletes doesn't grow back on the next open: the
        // manifest is already current, so the migration is done with it.
        let coverID = try #require(again.coverPage?.id)
        let deleted = try await store.deletePage(notebook: id, page: coverID)
        #expect(!deleted.hasCoverPage)
        let reopened = try await store.ensureCoverPage(notebook: id, style: PageStyle())
        #expect(!reopened.hasCoverPage)
    }

    @Test("The cover flag survives a manifest round trip")
    func coverFlagPersists() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        _ = try await store.createDocument(
            id: id, style: PageStyle(), pageCount: 1, includesCover: true
        )

        let reloaded = try await store.manifest(for: id)
        #expect(reloaded.pages.first?.isCover == true)
        #expect(reloaded.version == NotebookManifest.currentVersion)
    }

    @Test("A page record written before covers existed decodes as a normal page")
    func decodesWithoutCoverKey() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "template": "ruled",
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let page = try decoder.decode(PageRecord.self, from: Data(json.utf8))
        #expect(!page.isCover)
    }

    @Test("The rendered cover is saved beside the pages and read back")
    func savesCoverRender() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        _ = try await store.createDocument(
            id: id, style: PageStyle(), pageCount: 1, includesCover: true
        )

        #expect(await store.coverImageData(for: id) == nil)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try await store.saveCoverImage(png, for: id)
        #expect(await store.coverImageData(for: id) == png)
        // Re-rendering replaces it rather than piling up files.
        let second = Data([0x89, 0x50, 0x4E, 0x47, 0x00])
        try await store.saveCoverImage(second, for: id)
        #expect(await store.coverImageData(for: id) == second)
    }

    @Test("A notebook decides for itself whether it has a cover page")
    func usesCoverPage() {
        let plain = Notebook(title: "Bio", coverColorHex: "#416835")
        #expect(plain.usesCoverPage)
        #expect(plain.coverPaper.title == "Bio")
        #expect(plain.coverPaper.coverColorHex == "#416835")

        let coverOff = Notebook(title: "Scratch", coverColorHex: "#416835", showsCover: false)
        #expect(!coverOff.usesCoverPage)

        let board = Notebook(title: "Board", coverColorHex: "#416835", kind: .whiteboard)
        #expect(!board.usesCoverPage)

        let scan = Notebook(title: "Scan", coverColorHex: "#416835", kind: .scan)
        #expect(!scan.usesCoverPage)
    }

    @Test("The cover render travels with the notebook sync body")
    func syncBodyCarriesCover() throws {
        let body = NotebookSyncBody(
            title: "Bio", coverColorHex: "#416835", template: "ruled",
            shelfId: nil, pageCount: 3, createdAt: .now, updatedAt: .now,
            coverImage: "data:image/png;base64,AAAA"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Read the value back rather than grepping the text: Foundation writes the
        // data URL's slash as `\/`, which is valid JSON the server unescapes.
        let object = try JSONSerialization.jsonObject(with: try encoder.encode(body))
        let fields = try #require(object as? [String: Any])
        #expect(fields["coverImage"] as? String == "data:image/png;base64,AAAA")
    }
}
