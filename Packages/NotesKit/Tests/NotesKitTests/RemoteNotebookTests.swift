import ClassMateTheme
import Foundation
@testable import NotesModels
@testable import NotesServices
import SwiftData
import Testing
import UIKit

/// Notebooks that live on another device (`Notebook.isRemoteOnly`): nothing
/// here may make a blank "notebook" in their place, a stand-in an older build
/// made is set aside, and "Edit on this iPad" brings every page over.
///
/// 1.5 (84) on a real iPad: the launch push and the search indexer read every
/// row, `DocumentStore.manifest(for:)` answered a notebook with no package by
/// WRITING a blank one-page manifest, and the next launch took that for the
/// notebook — so it opened empty in the editor, and leaving pushed the blank
/// page over the real ones on the server.
@MainActor
@Suite("Remote-only notebooks", .serialized)
struct RemoteNotebookTests {
    private struct Harness {
        let repository: NotebookRepository
        let context: ModelContext
        let container: ModelContainer
        let store: DocumentStore
        let root: URL
    }

    private func makeHarness() -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-remote-\(UUID().uuidString)", isDirectory: true)
        let container = ModelContainerFactory.make(inMemory: true)
        let store = DocumentStore(rootURL: root)
        let repository = NotebookRepository(
            context: container.mainContext, store: store,
            entitlements: EntitlementService(listenForUpdates: false)
        )
        return Harness(
            repository: repository, context: container.mainContext,
            container: container, store: store, root: root
        )
    }

    /// A notebook the account has and this device doesn't: a remote-only row,
    /// made a day ago on another device.
    private func remoteRow(_ harness: Harness, pageCount: Int = 3) async throws -> Notebook {
        let id = UUID()
        await harness.repository.applyRemoteLibrary(RemoteLibrary(notebooks: [
            RemoteLibrary.Entry(
                id: id.uuidString, title: "From the other device",
                coverColorHex: ThemePreset.nord.accent.hexString,
                coverImage: nil, template: "isometric", shelfId: nil, pageCount: pageCount,
                createdAt: .now.addingTimeInterval(-86_400), updatedAt: .now.addingTimeInterval(-3_600)
            )
        ]))
        let row = try #require(try harness.context.fetch(FetchDescriptor<Notebook>()).first { $0.id == id })
        #expect(row.isRemoteOnly)
        return row
    }

    /// Exactly the shape 1.5 (84) left on the iPad: a pages folder with nothing
    /// in it and a v6 manifest of one blank page, made long after the notebook.
    private func writeStandIn(for id: UUID, in root: URL, pageCreatedAt: Date = .now) throws {
        let package = root.appendingPathComponent("\(id.uuidString).cmnote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("pages", isDirectory: true), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = NotebookManifest(version: 6, pages: [PageRecord(template: .blank, createdAt: pageCreatedAt)])
        try encoder.encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
    }

    private func packageExists(_ id: UUID, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id.uuidString).cmnote").path)
    }

    private func setAside(in root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("Set Aside", isDirectory: true).path
        )) ?? []
    }

    // MARK: - Nothing makes a blank notebook in their place

    @Test("Reading a notebook that isn't on this device creates nothing")
    func readingCreatesNothing() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = UUID()
        await #expect(throws: DocumentStore.DocumentError.noSuchNotebook) {
            try await harness.store.manifest(for: id)
        }
        #expect(packageExists(id, in: harness.root) == false)
    }

    @Test("The search indexer reads nothing for a remote-only notebook, and writes nothing")
    func indexerCreatesNothing() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let row = try await remoteRow(harness)
        let index = await SearchIndexer(store: harness.store).index(notebook: row.id)
        #expect(index.pages.isEmpty)
        try await harness.store.saveSearchIndex(index, for: row.id)
        #expect(packageExists(row.id, in: harness.root) == false)
    }

    @Test("The launch push leaves remote-only notebooks out; a rename sends the server's own page count")
    func pushLeavesRemoteOnlyOut() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let row = try await remoteRow(harness, pageCount: 3)
        let local = try await harness.repository.create(
            title: "Mine", coverColor: ThemePreset.light.accent, style: PageStyle(template: .grid)
        )
        let pushed = harness.repository.fullSnapshot().notebooks.map(\.id)
        #expect(pushed == [local.id])
        #expect(harness.repository.snapshot(row).remotePageCount == 3)
        #expect(harness.repository.snapshot(local).remotePageCount == nil)
    }

    @Test("iCloud sync is never handed a remote-only row as one of this device's notebooks")
    func cloudSyncLeavesRemoteOnlyOut() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let row = try await remoteRow(harness)
        let local = try await harness.repository.create(
            title: "Mine", coverColor: ThemePreset.light.accent, style: PageStyle(template: .grid)
        )
        let rows = harness.repository.rowIDs()
        #expect(rows.all == [local.id])
        #expect(rows.all.contains(row.id) == false)
    }

    @Test("The editor makes a package for a notebook of this device's that lost its own — and never over one")
    func editorCreatesMissingPackage() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = UUID()
        let style = PageStyle(template: .dotted)
        try await harness.store.createDocumentIfMissing(id: id, style: style, includesCover: true)
        let made = try await harness.store.manifest(for: id)
        #expect(made.pages.count == 2)
        #expect(made.coverPage != nil)
        _ = try await harness.store.addPage(to: id, template: .grid)
        try await harness.store.createDocumentIfMissing(id: id, style: style, includesCover: true)
        #expect(try await harness.store.manifest(for: id).pages.count == 3, "an existing package is left alone")
    }

    // MARK: - A stand-in from 1.5 (84) is set aside

    @Test("A stand-in left for a remote-only notebook is set aside, and the notebook stays read-only")
    func standInSetAside() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let row = try await remoteRow(harness)
        try writeStandIn(for: row.id, in: harness.root)
        await harness.repository.mirrorInfo([row])

        _ = await harness.repository.reconcileWithDisk()

        #expect(row.isRemoteOnly)
        #expect(packageExists(row.id, in: harness.root) == false)
        #expect(setAside(in: harness.root).count == 1, "kept, never deleted")
        #expect(await harness.store.packageIDs().isEmpty)
    }

    @Test("A row 1.5 (84) had already taken for local goes back to the server's pages")
    func flippedRowRestored() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let row = try await remoteRow(harness)
        try writeStandIn(for: row.id, in: harness.root)
        row.isRemoteOnly = false

        _ = await harness.repository.reconcileWithDisk()

        #expect(row.isRemoteOnly)
        #expect(packageExists(row.id, in: harness.root) == false)
    }

    @Test("A stand-in open in the editor is left exactly where it is")
    func standInInUseLeftAlone() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let row = try await remoteRow(harness)
        try writeStandIn(for: row.id, in: harness.root)
        row.isRemoteOnly = false
        await harness.store.beginEditing(row.id)

        _ = await harness.repository.reconcileWithDisk()

        #expect(row.isRemoteOnly == false)
        #expect(packageExists(row.id, in: harness.root))
    }

    @Test("Nothing real is ever taken for a stand-in")
    func realNotebooksAreNotStandIns() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        // Made a moment ago and never written in: as empty as a stand-in.
        let fresh = try await harness.repository.create(
            title: "New", coverColor: ThemePreset.light.accent, style: PageStyle(template: .blank)
        )
        #expect(await harness.store.isStandIn(fresh.id, notebookCreatedAt: fresh.createdAt) == false)

        // A v6 page made WITH its notebook, as every older build did.
        let old = UUID()
        let made = Date.now.addingTimeInterval(-86_400)
        try writeStandIn(for: old, in: harness.root, pageCreatedAt: made)
        #expect(await harness.store.isStandIn(old, notebookCreatedAt: made) == false)

        // The stand-in's exact shape, but somebody wrote on it.
        let written = UUID()
        try writeStandIn(for: written, in: harness.root)
        let manifest = try await harness.store.manifest(for: written)
        try await harness.store.savePageData(Data([1, 2, 3]), notebook: written, page: manifest.pages[0].id)
        #expect(await harness.store.isStandIn(written, notebookCreatedAt: made) == false)

        // And the real thing, for the record.
        let standIn = UUID()
        try writeStandIn(for: standIn, in: harness.root)
        #expect(await harness.store.isStandIn(standIn, notebookCreatedAt: made))
    }

    @Test("The stand-in pulled off a real iPad running 1.5 (84) is recognised")
    func realStandInRecognised() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = UUID()
        let package = harness.root.appendingPathComponent("\(id.uuidString).cmnote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("pages", isDirectory: true), withIntermediateDirectories: true
        )
        // Byte for byte what that build wrote (it carries no content at all).
        let manifest = """
        {
          "pages" : [
            {
              "createdAt" : "2026-10-09T15:27:08Z",
              "elements" : [

              ],
              "id" : "7429F914-A539-4ACE-B1B0-9F936ECF7872",
              "isBookmarked" : false,
              "isCover" : false,
              "lineSpacingSteps" : 5,
              "margin" : {
                "offset" : 72,
                "position" : "leading"
              },
              "orientation" : "portrait",
              "pageSize" : "classic",
              "template" : "blank"
            }
          ],
          "version" : 6
        }
        """
        try Data(manifest.utf8).write(to: package.appendingPathComponent("manifest.json"))
        let notebookMade = try #require(ISO8601DateFormatter().date(from: "2026-10-08T15:29:04Z"))
        #expect(await harness.store.isStandIn(id, notebookCreatedAt: notebookMade))
    }

    @Test("A remote-only row whose real package arrives still opens as a normal notebook")
    func realPackageClearsRemoteOnly() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let row = try await remoteRow(harness)
        try await harness.store.createDocument(id: row.id, style: PageStyle(template: .grid))

        _ = await harness.repository.reconcileWithDisk()

        #expect(row.isRemoteOnly == false)
        #expect(packageExists(row.id, in: harness.root))
    }

}

// MARK: - Edit on this iPad

extension RemoteNotebookTests {

    /// A page as the server pictures it: rendered at `PagePictureFit.renderScale`, JPEG.
    private func picture(_ size: PageSize, _ orientation: PageOrientation, in folder: URL) throws -> URL {
        let logical = size.size(orientation: orientation)
        let pixels = CGSize(
            width: (logical.width * PagePictureFit.renderScale).rounded(),
            height: (logical.height * PagePictureFit.renderScale).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let jpeg = try #require(UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixels))
        }.jpegData(compressionQuality: 0.8))
        let url = folder.appendingPathComponent("\(UUID().uuidString).png")
        try jpeg.write(to: url)
        return url
    }

    @Test("Edit on this iPad brings every page over, in order, with its voice notes and links")
    func editOnThisIPad() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let cache = harness.root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let row = try await remoteRow(harness)
        let recording = cache.appendingPathComponent("page-1-attachment-0.m4a")
        try Data(repeating: 7, count: 64).write(to: recording)
        let pages = [
            RemoteNotebookCache.Page(id: 0, imageURL: try picture(.classic, .portrait, in: cache), attachments: []),
            RemoteNotebookCache.Page(id: 1, imageURL: try picture(.a4, .landscape, in: cache), attachments: [
                RemoteNotebookCache.Attachment(
                    kind: "audio", name: "Lecture", durationSeconds: 42, fileURL: recording, linkURL: nil
                ),
                RemoteNotebookCache.Attachment(
                    kind: "link", name: "Syllabus", durationSeconds: nil, fileURL: nil,
                    linkURL: "https://example.com/syllabus"
                )
            ]),
            RemoteNotebookCache.Page(id: 2, imageURL: try picture(.a4, .landscape, in: cache), attachments: [])
        ]
        let cover = Data([0x89, 0x50, 0x4E, 0x47])

        try await harness.repository.adoptRemote(row, pages: pages, coverRender: cover)

        #expect(row.isRemoteOnly == false)
        let manifest = try await harness.store.manifest(for: row.id)
        #expect(manifest.pages.count == 3)
        #expect(manifest.pages[0].isCover, "the server had a cover render: page one is the cover")
        #expect(manifest.pages[0].pageSize == .classic)
        #expect(manifest.pages.allSatisfy { $0.backgroundPayloadFilename != nil })
        #expect(manifest.pages[1].pageSize == .a4 && manifest.pages[1].orientation == .landscape)
        #expect(row.pageSize == .a4 && row.orientation == .landscape, "new pages match the ones that came over")

        let elements = manifest.pages[1].elements
        let voice = try #require(elements.first { $0.kind == .audio })
        #expect(voice.durationSeconds == 42)
        #expect(voice.displayName == "Lecture")
        let filename = try #require(voice.payloadFilename)
        #expect(await harness.store.mediaData(notebook: row.id, filename: filename) == Data(repeating: 7, count: 64))
        #expect(elements.first { $0.kind == .link }?.urlString == "https://example.com/syllabus")
        for element in elements {
            let bounds = CGRect(origin: .zero, size: manifest.pages[1].logicalSize)
            #expect(bounds.contains(CGRect(x: element.x, y: element.y, width: element.width, height: element.height)))
        }
        #expect(await harness.store.coverImageData(for: row.id) == cover)
        #expect(await harness.store.info(for: row.id)?.title == "From the other device")
    }

    @Test("Edit on this iPad refuses a page whose voice note didn't come down, and changes nothing")
    func editRefusesIncompletePages() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let cache = harness.root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let row = try await remoteRow(harness)
        let pages = [
            RemoteNotebookCache.Page(id: 0, imageURL: try picture(.classic, .portrait, in: cache), attachments: [
                RemoteNotebookCache.Attachment(
                    kind: "audio", name: "Lecture", durationSeconds: 42, fileURL: nil, linkURL: nil
                )
            ])
        ]
        await #expect(throws: RemoteNotebookCache.FetchError.self) {
            try await harness.repository.adoptRemote(row, pages: pages, coverRender: nil)
        }
        #expect(row.isRemoteOnly)
        #expect(packageExists(row.id, in: harness.root) == false)
    }

    @Test("A notebook the server has no pictures of starts fresh here")
    func editWithNoPictures() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let row = try await remoteRow(harness)
        try await harness.repository.adoptRemote(row, pages: [], coverRender: nil)
        #expect(row.isRemoteOnly == false)
        let manifest = try await harness.store.manifest(for: row.id)
        #expect(manifest.pages.count == (row.usesCoverPage ? 2 : 1))
    }

    @Test("Pages built from pictures never land on a package that's already here")
    func picturesNeverOverwrite() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = UUID()
        try await harness.store.createDocument(id: id, style: PageStyle(template: .grid))
        let page = DocumentStore.PicturePage(
            picture: Data([0xFF, 0xD8, 0xFF]), pictureExtension: "jpg", style: PageStyle(template: .blank)
        )
        await #expect(throws: DocumentStore.DocumentError.alreadyExists) {
            try await harness.store.createDocument(id: id, fromPictures: [page])
        }
        #expect(try await harness.store.manifest(for: id).pages.first?.template == .grid)
    }
}
