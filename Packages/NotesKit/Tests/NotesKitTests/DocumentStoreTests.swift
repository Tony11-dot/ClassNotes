import Foundation
import NotesModels
import Testing
@testable import NotesServices

/// The durability contract: document packages survive corrupt or partial
/// files without data loss.
@Suite("DocumentStore recovery")
struct DocumentStoreTests {
    private func makeStore() -> (DocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-tests-\(UUID().uuidString)", isDirectory: true)
        return (DocumentStore(rootURL: root), root)
    }

    @Test("Create → load round-trips manifest and ink")
    func roundTrip() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let created = try await store.createDocument(id: id, firstPageTemplate: .ruled)
        #expect(created.pages.count == 1)
        #expect(created.pages[0].template == .ruled)

        let ink = Data("fake-ink".utf8)
        try await store.savePageData(ink, notebook: id, page: created.pages[0].id)

        let loaded = try await store.manifest(for: id)
        #expect(loaded.pages.map(\.id) == created.pages.map(\.id))
        #expect(loaded.pages.map(\.template) == created.pages.map(\.template))
        let loadedInk = await store.pageData(notebook: id, page: created.pages[0].id)
        #expect(loadedInk == ink)
    }

    @Test("Corrupt manifest is rebuilt from page blobs — ink survives")
    func corruptManifest() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let manifest = try await store.createDocument(id: id, firstPageTemplate: .grid)
        let pageID = manifest.pages[0].id
        let ink = Data("precious-ink".utf8)
        try await store.savePageData(ink, notebook: id, page: pageID)

        // Simulate a crash mid-write: manifest.json is garbage.
        let manifestURL = await store.documentURL(for: id).appendingPathComponent("manifest.json")
        try Data("{not json!!".utf8).write(to: manifestURL)

        let recovered = try await store.manifest(for: id)
        #expect(recovered.pages.map(\.id) == [pageID])
        let survivingInk = await store.pageData(notebook: id, page: pageID)
        #expect(survivingInk == ink)

        // Recovery is persisted — the next load must parse cleanly.
        let reloaded = try await store.manifest(for: id)
        #expect(reloaded.pages.map(\.id) == recovered.pages.map(\.id))
    }

    @Test("Orphan page blobs are re-adopted into the manifest")
    func orphanAdoption() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let manifest = try await store.createDocument(id: id, firstPageTemplate: .ruled)
        let knownPage = manifest.pages[0].id

        // A page blob that no manifest mentions (e.g. manifest write was lost).
        let orphanID = UUID()
        try await store.savePageData(Data("orphan-ink".utf8), notebook: id, page: orphanID)

        let recovered = try await store.manifest(for: id)
        #expect(Set(recovered.pages.map(\.id)) == [knownPage, orphanID])
    }

    @Test("A manifest page with no blob stays a valid empty page")
    func missingBlob() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        var manifest = try await store.createDocument(id: id, firstPageTemplate: .dotGrid)
        manifest = try await store.addPage(to: id, template: .blank)
        #expect(manifest.pages.count == 2)

        let loaded = try await store.manifest(for: id)
        #expect(loaded.pages.count == 2)
        let blob = await store.pageData(notebook: id, page: loaded.pages[1].id)
        #expect(blob == nil)
    }

    @Test("Totally empty document directory recovers to one blank page")
    func emptyDocument() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .ruled)
        let manifestURL = await store.documentURL(for: id).appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestURL)

        let recovered = try await store.manifest(for: id)
        #expect(recovered.pages.count == 1)
        #expect(recovered.pages[0].template == .blank)
    }

    @Test("Delete removes the whole package")
    func deleteDocument() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .ruled)
        let exists = await store.documentExists(id: id)
        #expect(exists)
        try await store.deleteDocument(id: id)
        let gone = await store.documentExists(id: id)
        #expect(!gone)
    }

    @Test("Adding pages appends in order and persists")
    func addPages() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .ruled)
        _ = try await store.addPage(to: id, template: .grid)
        let manifest = try await store.addPage(to: id, template: .blank)
        #expect(manifest.pages.map(\.template) == [.ruled, .grid, .blank])

        let reloaded = try await store.manifest(for: id)
        #expect(reloaded.pages.map(\.template) == [.ruled, .grid, .blank])
    }
}
