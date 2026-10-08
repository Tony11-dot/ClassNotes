import Foundation
import NotesModels
import Testing
@testable import NotesServices

private func makeStore(_ label: String) -> (DocumentStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmnotes-\(label)-\(UUID().uuidString)", isDirectory: true)
    return (DocumentStore(rootURL: root), root)
}

private func files(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

/// A damaged manifest costs at most what was damaged — never the notebook's
/// images, text, fills, bookmarks or page settings, and never the original bytes.
@Suite("Manifest safety")
struct ManifestSafetyTests {

    private func notebookWithContent(_ store: DocumentStore) async throws -> (UUID, UUID) {
        let id = UUID()
        let created = try await store.createDocument(id: id, firstPageTemplate: .grid)
        let page = created.pages[0].id
        try await store.setElements(
            [PageElement(kind: .text, x: 10, y: 10, width: 100, height: 40, text: "Mitochondria")],
            notebook: id, page: page
        )
        try await store.setBookmark(notebook: id, page: page, isBookmarked: true, name: "Exam")
        return (id, page)
    }

    @Test("Every manifest write keeps the previous one as a backup")
    func writeKeepsBackup() async throws {
        let (store, root) = makeStore("backup")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, _) = try await notebookWithContent(store)
        let backup = await store.manifestBackupURL(for: id)
        let decoded = try JSONDecoder.iso.decode(NotebookManifest.self, from: Data(contentsOf: backup))
        // The backup is the state one write before the bookmark.
        #expect(decoded.pages[0].elements.count == 1)
        #expect(decoded.pages[0].isBookmarked == false)
    }

    @Test("A garbage manifest is set aside and the backup restores the notebook's content")
    func garbageManifestRestoresFromBackup() async throws {
        let (store, root) = makeStore("garbage")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, page) = try await notebookWithContent(store)
        let url = await store.manifestURL(for: id)
        try Data("{\"version\": 8, \"pa".utf8).write(to: url)

        let recovered = try await store.manifest(for: id)

        #expect(recovered.pages.map(\.id) == [page])
        #expect(recovered.pages[0].template == .grid, "page settings survive")
        #expect(recovered.pages[0].elements.first?.text == "Mitochondria", "elements survive")
        let kept = files(in: await store.documentURL(for: id)).filter { $0.hasPrefix("manifest.unreadable-") }
        #expect(kept.count == 1, "the damaged bytes are kept, never overwritten")
    }

    @Test("One unreadable element costs that element, not the page or the notebook")
    func salvageKeepsTheRest() async throws {
        let (store, root) = makeStore("salvage")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, page) = try await notebookWithContent(store)
        let url = await store.manifestURL(for: id)
        // Break the element's required frame field.
        var json = try String(contentsOf: url, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"width\" : 100", with: "\"width\" : \"wide\"")
        try json.write(to: url, atomically: true, encoding: .utf8)

        let recovered = try await store.manifest(for: id)

        #expect(recovered.pages.map(\.id) == [page])
        #expect(recovered.pages[0].isBookmarked, "the newest state survives, bookmark and all")
        #expect(recovered.pages[0].bookmarkName == "Exam")
    }

    @Test("A template, size or tape pattern from a newer build doesn't make the notebook unreadable")
    func unknownValuesDecode() async throws {
        let (store, root) = makeStore("future")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, page) = try await notebookWithContent(store)
        let url = await store.manifestURL(for: id)
        var json = try String(contentsOf: url, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"template\" : \"grid\"", with: "\"template\" : \"hexPlanner\"")
        json = json.replacingOccurrences(of: "\"pageSize\" : \"classic\"", with: "\"pageSize\" : \"letterPlus\"")
        try json.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try await store.manifest(for: id)

        #expect(loaded.pages.map(\.id) == [page])
        #expect(loaded.pages[0].template == .blank)
        #expect(loaded.pages[0].pageSize == .classic)
        #expect(loaded.pages[0].elements.first?.text == "Mitochondria")
    }

    @Test("A manifest written by a newer build is kept before this build first rewrites it")
    func newerManifestPreserved() async throws {
        let (store, root) = makeStore("newer")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, _) = try await notebookWithContent(store)
        let url = await store.manifestURL(for: id)
        var json = try String(contentsOf: url, encoding: .utf8)
        json = json.replacingOccurrences(
            of: "\"version\" : \(NotebookManifest.currentVersion)", with: "\"version\" : 99"
        )
        json = json.replacingOccurrences(of: "\"pages\" : [", with: "\"futureField\" : 7, \"pages\" : [")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: url)

        _ = try await store.addPage(to: id, template: .blank)

        let kept = await store.documentURL(for: id).appendingPathComponent("manifest.v99.json")
        #expect(try Data(contentsOf: kept) == original)
    }

    @Test("A write cut off between keeping the backup and landing the new file loads the backup")
    func interruptedWriteLoadsBackup() async throws {
        let (store, root) = makeStore("interrupted")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, page) = try await notebookWithContent(store)
        let url = await store.manifestURL(for: id)
        // What the rename-then-write leaves if the process dies in between: the
        // current manifest has become the backup, and nothing replaced it.
        _ = Darwin.rename(url.path, await store.manifestBackupURL(for: id).path)

        #expect(await store.documentExists(id: id))
        let loaded = try await store.manifest(for: id)
        #expect(loaded.pages.map(\.id) == [page])
        #expect(loaded.pages[0].elements.count == 1)
        #expect(loaded.pages[0].isBookmarked, "the latest complete state, not an older one")
    }

    @Test("A second unreadable page blob is kept too, not deleted")
    func everyUnreadableBlobKept() async throws {
        let (store, root) = makeStore("blobs")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let page = try await store.createDocument(id: id, firstPageTemplate: .blank).pages[0].id
        try await store.savePageData(Data("bad one".utf8), notebook: id, page: page)
        await store.quarantinePageData(notebook: id, page: page)
        try await store.savePageData(Data("bad two".utf8), notebook: id, page: page)
        await store.quarantinePageData(notebook: id, page: page)

        let kept = files(in: await store.pagesDirectory(for: id)).filter { $0.contains(".unreadable") }
        #expect(kept.count == 2)
    }
}

/// Deleting a page is a move to the notebook's trash, undoable at once and for
/// thirty days after.
@Suite("Page trash")
struct PageTrashTests {

    private func notebook(_ store: DocumentStore, pages: Int) async throws -> (UUID, [UUID]) {
        let id = UUID()
        _ = try await store.createDocument(id: id, style: PageStyle(template: .ruled), pageCount: pages)
        let ids = try await store.manifest(for: id).pages.map(\.id)
        for (index, page) in ids.enumerated() {
            try await store.savePageData(Data("ink \(index)".utf8), notebook: id, page: page)
        }
        return (id, ids)
    }

    @Test("Delete then restore puts the page back where it was, ink, elements and media")
    func restoreRoundTrip() async throws {
        let (store, root) = makeStore("trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 3)
        let media = try await store.saveMedia(Data("photo".utf8), notebook: id, fileExtension: "png")
        try await store.setElements(
            [PageElement(kind: .image, x: 0, y: 0, width: 10, height: 10, payloadFilename: media)],
            notebook: id, page: pages[1]
        )

        let after = try await store.deletePage(notebook: id, page: pages[1])
        #expect(after.pages.map(\.id) == [pages[0], pages[2]])
        #expect(await store.pageData(notebook: id, page: pages[1]) == nil)
        #expect(await store.trashedPages(notebook: id).map(\.id) == [pages[1]])
        #expect(await store.mediaData(notebook: id, filename: media) != nil)

        let restored = try await store.restorePage(notebook: id, page: pages[1])
        #expect(restored.pages.map(\.id) == pages)
        #expect(await store.pageData(notebook: id, page: pages[1]) == Data("ink 1".utf8))
        #expect(restored.pages[1].elements.first?.payloadFilename == media)
        #expect(await store.trashedPages(notebook: id).isEmpty)
    }

    @Test("Several pages deleted, restored in reverse, come back in their original order")
    func multiDeleteOrder() async throws {
        let (store, root) = makeStore("multi")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 5)
        for page in [pages[0], pages[2], pages[4]] {
            try await store.deletePage(notebook: id, page: page)
        }
        for page in [pages[4], pages[2], pages[0]] {
            try await store.restorePage(notebook: id, page: page)
        }
        #expect(try await store.manifest(for: id).pages.map(\.id) == pages)
    }

    @Test("Ink the canvas flushes after the delete lands in the trash, so Undo has every stroke")
    func lateSaveGoesToTrash() async throws {
        let (store, root) = makeStore("late")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 2)
        try await store.deletePage(notebook: id, page: pages[0])
        try await store.savePageData(Data("last strokes".utf8), notebook: id, page: pages[0])

        #expect(try await store.manifest(for: id).pages.map(\.id) == [pages[1]], "no phantom page")
        try await store.restorePage(notebook: id, page: pages[0])
        #expect(await store.pageData(notebook: id, page: pages[0]) == Data("last strokes".utf8))
    }

    @Test("Staged ink not yet on disk is what goes into the trash")
    func stagedInkIsTrashed() async throws {
        let (store, root) = makeStore("staged")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 2)
        store.journal.stage(Data("newest".utf8), page: pages[0], stamp: store.journal.stamp())
        try await store.deletePage(notebook: id, page: pages[0])
        try await store.restorePage(notebook: id, page: pages[0])
        #expect(await store.pageData(notebook: id, page: pages[0]) == Data("newest".utf8))
    }

    @Test("Pages expire after the grace period: ink and unshared media go, nothing else")
    func purgeAfterRetention() async throws {
        let (store, root) = makeStore("purge")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 2)
        let own = try await store.saveMedia(Data("own".utf8), notebook: id, fileExtension: "png")
        try await store.setElements(
            [PageElement(kind: .image, x: 0, y: 0, width: 1, height: 1, payloadFilename: own)],
            notebook: id, page: pages[0]
        )
        try await store.deletePage(notebook: id, page: pages[0])

        #expect(try await store.purgeExpiredPages(notebook: id, now: .now.addingTimeInterval(86_400)) == 0)
        let later = Date.now.addingTimeInterval(TrashPolicy.retention + 60)
        #expect(try await store.purgeExpiredPages(notebook: id, now: later) == 1)

        #expect(await store.trashedPages(notebook: id).isEmpty)
        #expect(await store.mediaData(notebook: id, filename: own) == nil)
        let leftovers = files(in: await store.pagesDirectory(for: id)).filter { $0.contains(pages[0].uuidString) }
        #expect(leftovers.isEmpty)
        #expect(await store.pageData(notebook: id, page: pages[1]) == Data("ink 1".utf8))
    }

    @Test("A delete cut off after the manifest but before the blob moved never comes back as a phantom page")
    func interruptedDeleteNoPhantom() async throws {
        let (store, root) = makeStore("cutoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 2)
        try await store.deletePage(notebook: id, page: pages[0])
        // Undo the last step of the delete by hand: the blob still live-named.
        let trashed = await store.trashedPageURL(notebook: id, page: pages[0])
        let live = await store.pageURL(notebook: id, page: pages[0])
        try FileManager.default.moveItem(at: trashed, to: live)

        let fresh = DocumentStore(rootURL: root)
        #expect(try await fresh.manifest(for: id).pages.map(\.id) == [pages[1]])
        try await fresh.restorePage(notebook: id, page: pages[0])
        #expect(await fresh.pageData(notebook: id, page: pages[0]) == Data("ink 0".utf8))
    }

    @Test("A manifest damaged right after a delete brings the page back WITH its ink, and saves land on it")
    func backupRollbackRevivesInk() async throws {
        let (store, root) = makeStore("revive")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 2)
        try await store.deletePage(notebook: id, page: pages[0])
        // Damage the manifest: the backup is the state from before the delete.
        try Data("{ not json".utf8).write(to: await store.manifestURL(for: id))

        let recovered = try await store.manifest(for: id)
        #expect(recovered.pages.map(\.id) == pages)
        #expect(await store.pageData(notebook: id, page: pages[0]) == Data("ink 0".utf8), "not blank")
        #expect(await store.trashedPages(notebook: id).isEmpty, "a live page isn't in Recently Deleted")
        // Same session: the id is no longer tombstoned, so new ink is live.
        try await store.savePageData(Data("after".utf8), notebook: id, page: pages[0])
        #expect(await store.pageData(notebook: id, page: pages[0]) == Data("after".utf8))
        #expect(try await DocumentStore(rootURL: root).manifest(for: id).pages.map(\.id) == pages)
    }

    @Test("A purged page stays gone even if the manifest is then damaged")
    func purgedPageNotInBackup() async throws {
        let (store, root) = makeStore("purged")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 2)
        try await store.deletePage(notebook: id, page: pages[0])
        try await store.purgePages([pages[0]], notebook: id)
        try FileManager.default.removeItem(at: await store.manifestURL(for: id))

        #expect(try await DocumentStore(rootURL: root).manifest(for: id).pages.map(\.id) == [pages[1]])
    }

    @Test("Adopting a stray page blob keeps the user's page order")
    func orphanKeepsOrder() async throws {
        let (store, root) = makeStore("order")
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, pages) = try await notebook(store, pages: 3)
        try await store.movePage(notebook: id, from: 2, to: 0)
        let stray = UUID()
        try await store.savePageData(Data("stray".utf8), notebook: id, page: stray)

        let loaded = try await DocumentStore(rootURL: root).manifest(for: id).pages.map(\.id)
        #expect(loaded == [pages[2], pages[0], pages[1], stray])
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
