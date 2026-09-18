import Foundation
import NotesModels
import Testing
@testable import NotesServices

/// Page management (insert / delete / move / duplicate / settings) and the
/// margin model that backs the editor's page manager + page settings.
@Suite("Page management")
struct PageManagementTests {
    private func makeStore() -> (DocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-pagemgmt-\(UUID().uuidString)", isDirectory: true)
        return (DocumentStore(rootURL: root), root)
    }

    @Test("Insert at index, inheriting template + margin")
    func insert() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .grid)

        let (m1, page) = try await store.insertPage(
            notebook: id, at: 0, template: .dotGrid, margin: PageMargin(position: .trailing)
        )
        #expect(m1.pages.count == 2)
        #expect(m1.pages.first?.id == page.id)
        #expect(m1.pages.first?.template == .dotGrid)
        #expect(m1.pages.first?.margin.position == .trailing)
    }

    @Test("Move reorders pages")
    func move() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .blank)
        _ = try await store.insertPage(notebook: id, at: 1, template: .ruled, margin: .default)
        let before = try await store.manifest(for: id)
        let firstID = before.pages[0].id

        let moved = try await store.movePage(notebook: id, from: 0, to: 1)
        #expect(moved.pages.count == 2)
        #expect(moved.pages[1].id == firstID)
    }

    @Test("Delete removes the page; last page is never lost")
    func delete() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let created = try await store.createDocument(id: id, firstPageTemplate: .blank)
        let onlyPage = created.pages[0].id

        _ = try await store.insertPage(notebook: id, at: 1, template: .grid, margin: .default)
        let afterOne = try await store.deletePage(notebook: id, page: onlyPage)
        #expect(afterOne.pages.count == 1)
        #expect(!afterOne.pages.contains { $0.id == onlyPage })

        // Deleting the final page leaves a fresh blank one, never zero.
        let last = afterOne.pages[0].id
        let afterLast = try await store.deletePage(notebook: id, page: last)
        #expect(afterLast.pages.count == 1)
    }

    @Test("Delete sweeps a page's own media, but never a filename another page still uses")
    func deleteSweepsOrphanedMedia() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let created = try await store.createDocument(id: id, firstPageTemplate: .blank)
        let firstPage = created.pages[0].id
        let (afterInsert, secondRecord) = try await store.insertPage(
            notebook: id, at: 1, template: .blank, margin: .default
        )
        let secondPage = secondRecord.id
        #expect(afterInsert.pages.count == 2)

        // Page one owns an image nobody else references; page two owns one AND
        // shares a second filename with page one (as a duplicate would).
        let orphaned = try await store.saveMedia(Data("orphan".utf8), notebook: id, fileExtension: "png")
        let shared = try await store.saveMedia(Data("shared".utf8), notebook: id, fileExtension: "png")
        try await store.setElements(
            [PageElement(kind: .image, x: 0, y: 0, width: 10, height: 10, payloadFilename: shared)],
            notebook: id, page: secondPage
        )
        // Page one references BOTH: one filename nobody else uses, and one it
        // shares with page two, the way a duplicate's copy would.
        try await store.setElements(
            [
                PageElement(kind: .image, x: 0, y: 0, width: 10, height: 10, payloadFilename: orphaned),
                PageElement(kind: .image, x: 20, y: 20, width: 10, height: 10, payloadFilename: shared)
            ],
            notebook: id, page: firstPage
        )

        _ = try await store.deletePage(notebook: id, page: firstPage)

        let remainingOrphan = await store.mediaData(notebook: id, filename: orphaned)
        let remainingShared = await store.mediaData(notebook: id, filename: shared)
        #expect(remainingOrphan == nil)
        #expect(remainingShared != nil)
    }

    @Test("Duplicate copies settings and ink under a new id, right after source")
    func duplicate() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let created = try await store.createDocument(id: id, firstPageTemplate: .ruled)
        let src = created.pages[0].id
        try await store.savePageData(Data("ink".utf8), notebook: id, page: src)

        let dup = try await store.duplicatePage(notebook: id, page: src)
        #expect(dup.pages.count == 2)
        let copy = dup.pages[1]
        #expect(copy.id != src)
        #expect(copy.template == .ruled)
        let copiedInk = await store.pageData(notebook: id, page: copy.id)
        #expect(copiedInk == Data("ink".utf8))
    }

    @Test("Update page template + margin persists")
    func updateSettings() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let created = try await store.createDocument(id: id, firstPageTemplate: .blank)
        let page = created.pages[0].id

        _ = try await store.updatePage(
            notebook: id, page: page, template: .dotGrid,
            margin: PageMargin(position: .none, colorHex: nil, offset: 90)
        )
        let reloaded = try await store.manifest(for: id)
        #expect(reloaded.pages[0].template == .dotGrid)
        #expect(reloaded.pages[0].margin.position == .none)
        #expect(reloaded.pages[0].margin.offset == 90)
    }

    @Test("A v2 page (no margin key) loads with the default leading margin")
    func marginBackwardCompatible() throws {
        // Simulate a pre-margin PageRecord JSON.
        let json = """
        { "id": "\(UUID().uuidString)", "template": "ruled",
          "createdAt": 0, "elements": [] }
        """
        let decoder = JSONDecoder()
        let page = try decoder.decode(PageRecord.self, from: Data(json.utf8))
        #expect(page.margin.position == .leading)
        #expect(page.margin.colorHex == nil)
    }

    @Test("Font library exposes the curated pack with a stable default")
    func fontLibrary() {
        #expect(FontLibrary.default.id == "cabinet")
        #expect(FontLibrary.all.count >= 8)
        #expect(FontLibrary.font(id: "noteworthy").fontName == "Noteworthy-Light")
        // Unknown ids fall back to the brand face.
        #expect(FontLibrary.byNameOrID("does-not-exist").id == "cabinet")
        #expect(FontLibrary.byNameOrID("Menlo-Regular").id == "menlo")
    }
}
