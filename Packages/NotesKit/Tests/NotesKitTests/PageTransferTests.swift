import ClassMateTheme
import Foundation
import NotesModels
import SwiftData
import Testing
@testable import NotesServices

private func makeStore(_ label: String) -> (DocumentStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmnotes-transfer-\(label)-\(UUID().uuidString)", isDirectory: true)
    return (DocumentStore(rootURL: root), root)
}

/// Sending pages from one notebook to another: everything on the page goes
/// with it, and a crash or a failed write never costs a page.
@Suite("Moving and copying pages between notebooks")
struct PageTransferTests {

    /// A source with three inked pages (the middle one with a photo) and a
    /// one-page destination.
    private func notebooks(_ store: DocumentStore) async throws -> (source: UUID, pages: [UUID], target: UUID) {
        let source = UUID(), target = UUID()
        try await store.createDocument(id: source, style: PageStyle(template: .ruled), pageCount: 3)
        try await store.createDocument(id: target, style: PageStyle(template: .grid))
        let pages = try await store.manifest(for: source).pages.map(\.id)
        for (index, page) in pages.enumerated() {
            try await store.savePageData(Data("ink \(index)".utf8), notebook: source, page: page)
        }
        let photo = try await store.saveMedia(Data("photo".utf8), notebook: source, fileExtension: "png")
        try await store.setElements(
            [PageElement(kind: .image, x: 10, y: 10, width: 100, height: 80, payloadFilename: photo)],
            notebook: source, page: pages[1]
        )
        return (source, pages, target)
    }

    @Test("Copying puts full copies at the end of the other notebook and leaves the source alone")
    func copy() async throws {
        let (store, root) = makeStore("copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, pages, target) = try await notebooks(store)

        let result = try await store.transferPages(
            [pages[2], pages[1]], from: source, to: target, removingFromSource: false
        )
        #expect(result.added.count == 2)
        #expect(Set(result.added).isDisjoint(with: pages), "copies get their own ids")
        let landed = try await store.manifest(for: target).pages
        #expect(landed.count == 3)
        // Source order, whatever order they were picked in.
        #expect(await store.pageData(notebook: target, page: landed[1].id) == Data("ink 1".utf8))
        #expect(await store.pageData(notebook: target, page: landed[2].id) == Data("ink 2".utf8))
        let photo = try #require(landed[1].elements.first?.payloadFilename)
        #expect(await store.mediaData(notebook: target, filename: photo) == Data("photo".utf8))
        #expect(try await store.manifest(for: source).pages.map(\.id) == pages)
    }

    @Test("Moving sends the originals to the source's Recently Deleted, where they can be restored")
    func move() async throws {
        let (store, root) = makeStore("move")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, pages, target) = try await notebooks(store)

        let result = try await store.transferPages([pages[0]], from: source, to: target, removingFromSource: true)
        #expect(result.source.pages.map(\.id) == [pages[1], pages[2]])
        #expect(try await store.manifest(for: target).pages.count == 2)
        #expect(await store.trashedPages(notebook: source).map(\.id) == [pages[0]])
        try await store.restorePage(notebook: source, page: pages[0])
        #expect(await store.pageData(notebook: source, page: pages[0]) == Data("ink 0".utf8))
    }

    @Test("The cover stays with its notebook")
    func coverStays() async throws {
        let (store, root) = makeStore("cover")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = UUID(), target = UUID()
        let created = try await store.createDocument(
            id: source, style: PageStyle(template: .ruled), pageCount: 1, includesCover: true
        )
        try await store.createDocument(id: target, style: PageStyle(template: .ruled))
        let result = try await store.transferPages(
            created.pages.map(\.id), from: source, to: target, removingFromSource: true
        )
        #expect(result.added.count == 1)
        #expect(result.source.pages.first?.isCover == true)
        #expect(try await store.manifest(for: target).pages.allSatisfy { !$0.isCover })
    }

    @Test("Ink still on its way to disk is what gets sent")
    func stagedInkTravels() async throws {
        let (store, root) = makeStore("staged")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, pages, target) = try await notebooks(store)
        store.journal.stage(Data("newest".utf8), page: pages[0], stamp: store.journal.stamp())

        let result = try await store.transferPages([pages[0]], from: source, to: target, removingFromSource: false)
        #expect(await store.pageData(notebook: target, page: result.added[0]) == Data("newest".utf8))
    }

    @Test("A destination that can't be written gets nothing half-copied, and the source keeps its pages")
    func failedTransferLeavesNothing() async throws {
        let (store, root) = makeStore("fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, pages, target) = try await notebooks(store)
        let package = store.documentURL(for: target)
        // The package folder refuses the manifest; its pages folder still
        // takes the ink, which is exactly what must be cleaned up again.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        await #expect(throws: (any Error).self) {
            try await store.transferPages([pages[0], pages[2]], from: source, to: target, removingFromSource: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path)

        let fresh = DocumentStore(rootURL: root)
        #expect(try await fresh.manifest(for: target).pages.count == 1, "no orphan adopted as a page")
        #expect(try await fresh.manifest(for: source).pages.map(\.id) == pages, "a failed move deletes nothing")
    }
}

@MainActor
@Suite("Where pages can be sent")
struct PageDestinationTests {

    @Test("Only live, local, editable notebooks other than this one, most recent first")
    func destinations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-dest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = ModelContainerFactory.make(inMemory: true)
        let repository = NotebookRepository(
            context: container.mainContext, store: DocumentStore(rootURL: root),
            entitlements: EntitlementService(listenForUpdates: false)
        )
        let style = PageStyle(template: .ruled)
        let accent = ThemePreset.light.accent
        let current = try await repository.create(title: "Current", coverColor: accent, style: style)
        let older = try await repository.create(title: "Older", coverColor: accent, style: style)
        let newer = try await repository.create(title: "Newer", coverColor: accent, style: style)
        let trashed = try await repository.create(title: "Trashed", coverColor: accent, style: style)
        let viewOnly = try await repository.create(title: "View only", coverColor: accent, style: style)
        let remote = try await repository.create(title: "Remote", coverColor: accent, style: style)
        try repository.moveToTrash(trashed)
        viewOnly.isViewOnly = true
        remote.isRemoteOnly = true
        older.updatedAt = .now.addingTimeInterval(-60)
        newer.updatedAt = .now

        let titles = repository.pageDestinations(excluding: current.id).map(\.title)
        #expect(titles == ["Newer", "Older"])
    }
}
