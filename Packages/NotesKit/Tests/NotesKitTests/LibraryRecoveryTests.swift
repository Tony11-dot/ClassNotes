import ClassMateTheme
import Foundation
import SwiftData
import Testing
@testable import NotesEditor
@testable import NotesModels
@testable import NotesServices

/// Every notebook on disk is in the library — whatever happened to the
/// library's own database.
@MainActor
@Suite("Library recovery", .serialized)
struct LibraryRecoveryTests {
    private struct Harness {
        let repository: NotebookRepository
        let context: ModelContext
        let container: ModelContainer
        let store: DocumentStore
        let root: URL
    }

    private func makeHarness(root: URL? = nil) -> Harness {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-library-\(UUID().uuidString)", isDirectory: true)
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

    @Test("A new notebook's package describes itself")
    func createWritesInfo() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let notebook = try await harness.repository.create(
            title: "Biology", coverColor: ThemePreset.matcha.accent, style: PageStyle(template: .grid)
        )
        let info = await harness.store.info(for: notebook.id)
        #expect(info?.title == "Biology")
        #expect(info?.defaultTemplate == PageTemplate.grid.rawValue)
    }

    @Test("A notebook purged straight after it was trashed doesn't crash the deferred description write")
    func trashThenPurgeAtOnce() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let notebook = try await harness.repository.create(
            title: "Scratch", coverColor: ThemePreset.matcha.accent, style: PageStyle(template: .blank)
        )
        try harness.repository.moveToTrash(notebook)
        try await harness.repository.purge(notebook)
        // The write `moveToTrash` deferred now runs against a row that's gone.
        // It used to read the row then, which SwiftData answers with a trap.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.store.documentExists(id: notebook.id) == false)
    }

    @Test("A library whose database was lost is rebuilt from the packages — names, shelves, trash and all")
    func rebuildFromPackages() async throws {
        let first = makeHarness()
        defer { try? FileManager.default.removeItem(at: first.root) }
        let shelf = try first.repository.createShelf(name: "Semester 1", colorHex: ThemePreset.coffee.accent.hexString, symbolName: "bag")
        let kept = try await first.repository.create(
            title: "Physics", coverColor: ThemePreset.light.accent, style: PageStyle(template: .ruled), shelfID: shelf.id
        )
        let binned = try await first.repository.create(
            title: "Old drafts", coverColor: ThemePreset.light.accent, style: PageStyle(template: .blank)
        )
        try first.repository.moveToTrash(binned)
        await first.repository.mirrorInfo([kept, binned])

        // A brand-new, empty database over the same documents.
        let second = makeHarness(root: first.root)
        let result = await second.repository.reconcileWithDisk()

        #expect(result.recovered == 2)
        #expect(result.recoveredWithoutDescription == 0)
        let rows = try second.context.fetch(FetchDescriptor<Notebook>())
        let physics = rows.first { $0.id == kept.id }
        #expect(physics?.title == "Physics")
        #expect(physics?.shelfID == shelf.id)
        #expect(try second.context.fetch(FetchDescriptor<Shelf>()).first?.name == "Semester 1")
        #expect(rows.first { $0.id == binned.id }?.isTrashed == true, "trashed stays trashed")
    }

    @Test("A package with no description still comes back, as a recovered notebook")
    func placeholderForUndescribedPackage() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = UUID()
        try await harness.store.createDocument(id: id, style: PageStyle(template: .dotted), includesCover: true)

        let result = await harness.repository.reconcileWithDisk()

        #expect(result == LibraryReconciliation(recovered: 1, recoveredWithoutDescription: 1))
        let row = try harness.context.fetch(FetchDescriptor<Notebook>()).first
        #expect(row?.id == id)
        #expect(row?.title == "Recovered notebook")
        #expect(row?.showsCover == true)
        #expect(row?.defaultTemplate == .dotted)
        // And it now has a description of its own for next time.
        #expect(await harness.store.info(for: id)?.title == "Recovered notebook")
    }

    @Test("Reconciling a consistent library changes nothing")
    func idempotent() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        _ = try await harness.repository.create(
            title: "Maths", coverColor: ThemePreset.light.accent, style: PageStyle(template: .grid)
        )
        #expect(await harness.repository.reconcileWithDisk() == LibraryReconciliation())
        #expect(await harness.repository.reconcileWithDisk() == LibraryReconciliation())
        #expect(try harness.context.fetchCount(FetchDescriptor<Notebook>()) == 1)
    }

    @Test("A remote-only row whose ink is actually here is opened as a normal notebook")
    func clearsStaleRemoteOnly() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let notebook = try await harness.repository.create(
            title: "Chemistry", coverColor: ThemePreset.light.accent, style: PageStyle(template: .grid)
        )
        notebook.isRemoteOnly = true
        _ = await harness.repository.reconcileWithDisk()
        #expect(notebook.isRemoteOnly == false)
    }

    @Test("A rename reaches the package's description")
    func renameMirrors() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let notebook = try await harness.repository.create(
            title: "Draft", coverColor: ThemePreset.light.accent, style: PageStyle(template: .grid)
        )
        try harness.repository.rename(notebook, to: "History essay")
        var title: String?
        for _ in 0..<50 {
            title = await harness.store.info(for: notebook.id)?.title
            if title == "History essay" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(title == "History essay")
    }

    @Test("A description with damaged fields still recovers the notebook")
    func lenientInfo() throws {
        let id = UUID()
        let json = """
        {"id": "\(id.uuidString)", "title": 42, "createdAt": "yesterday", "isFavorite": true}
        """
        let info = try JSONDecoder().decode(NotebookInfo.self, from: Data(json.utf8))
        #expect(info.id == id)
        #expect(info.title == "Recovered notebook")
        #expect(info.isFavorite)
    }
}

@Suite("Library database recovery")
struct StoreRecoveryTests {
    @Test("An unopenable database is moved aside, kept, and replaced — never an empty in-memory library")
    func movesAside() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("default.store")
        try Data(repeating: 0x42, count: 4096).write(to: url)

        let (container, recovery) = ModelContainerFactory.makeRecovering(url: url)

        guard case .movedAside(let aside) = recovery else {
            Issue.record("expected the store to be moved aside, got \(String(describing: recovery))")
            return
        }
        #expect(try Data(contentsOf: aside.appendingPathComponent("default.store"))
            == Data(repeating: 0x42, count: 4096))
        // The fresh database is real and persistent.
        let context = ModelContext(container)
        context.insert(Notebook(title: "After", coverColorHex: ThemePreset.light.accent.hexString))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Notebook>()) == 1)
    }

    @Test("A healthy database opens with no recovery")
    func healthyOpens() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (_, recovery) = ModelContainerFactory.makeRecovering(url: folder.appendingPathComponent("ok.store"))
        #expect(recovery == nil)
    }

    @Test("The library database is local only: no configuration lets SwiftData reach for CloudKit")
    func configurationsAreLocalOnly() {
        // SwiftData's default is `.automatic`, which turns CloudKit on whenever
        // the app is signed with an iCloud container — the App Store build is,
        // for iCloud Drive. CloudKit forbids unique constraints and every model
        // keys on a unique id, so no container could open, the in-memory last
        // resort included: 1.5 (81)–(83) quit on launch on every device. The
        // test host is signed with nothing, so `.automatic` passes every other
        // test here; only the setting itself shows it. (Opening this schema
        // with `.private(...)` here reproduces the failure, but CloudKit's
        // teardown can hang the test host, so it isn't a test.)
        let local = String(describing: ModelConfiguration.CloudKitDatabase.none)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-store-\(UUID().uuidString).store")
        for configuration in [
            ModelContainerFactory.configuration(inMemory: false, url: nil),
            ModelContainerFactory.configuration(inMemory: true, url: nil),
            ModelContainerFactory.configuration(inMemory: false, url: url)
        ] {
            #expect(String(describing: configuration.cloudKitDatabase) == local)
        }
    }

    @Test("Library notices say what happened, that notes are safe, and what changed")
    func notices() {
        #expect(LibraryNotice(storeRecovery: nil, reconciliation: LibraryReconciliation()) == nil)
        let found = LibraryNotice(storeRecovery: nil, reconciliation: LibraryReconciliation(recovered: 2))
        #expect(found?.message.contains("2 notebooks") == true)
        let rebuilt = LibraryNotice(
            storeRecovery: .movedAside(URL(fileURLWithPath: "/tmp")),
            reconciliation: LibraryReconciliation(recovered: 1)
        )
        #expect(rebuilt?.message.contains("Your notes are safe") == true)
    }
}

@Suite("Save problems in plain words")
struct SaveProblemTests {
    @Test("A full disk is recognised however deeply it is wrapped")
    func outOfSpace() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: posix])
        #expect(SaveProblem(wrapped).isOutOfSpace)
        #expect(SaveProblem(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)).isOutOfSpace)
        #expect(!SaveProblem(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)).isOutOfSpace)
    }

    @Test("Every message says the work on screen is still there")
    func reassures() {
        for problem in [SaveProblem(isOutOfSpace: true), SaveProblem(isOutOfSpace: false)] {
            #expect(problem.message.contains("still here"))
        }
    }
}

/// The editor never blanks a notebook because a write failed, and never lets a
/// later operation erase an edit that hasn't reached disk.
@MainActor
@Suite("Editor writes fail safely", .serialized)
struct EditorWriteSafetyTests {
    private func makeModel() async throws -> (NotebookEditorModel, DocumentStore, UUID, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-editor-\(UUID().uuidString)", isDirectory: true)
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        try await store.createDocument(id: id, firstPageTemplate: .ruled)
        let model = NotebookEditorModel(notebookID: id, store: store)
        await model.load()
        return (model, store, id, root)
    }

    /// Makes the package read-only — every atomic write in it then fails.
    private func setWritable(_ writable: Bool, _ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path
        )
    }

    @Test("A page operation that can't be saved keeps the notebook on screen and says so")
    func failedOperationKeepsManifest() async throws {
        let (model, store, id, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = model.pages
        try setWritable(false, store.documentURL(for: id))
        defer { try? setWritable(true, store.documentURL(for: id)) }

        await model.addPage(template: .grid)

        #expect(model.manifest != nil, "never a blank notebook")
        #expect(model.pages == before)
        #expect(model.saveProblem != nil)
    }

    @Test("An element edit that can't be saved is held, protected from later operations, and lands once it can")
    func heldElementsLand() async throws {
        let (model, store, id, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(model.pages.first?.id)
        model.focusedPageID = page
        try setWritable(false, store.documentURL(for: id))

        await model.insertText("Krebs cycle", fontName: "System", colorHex: ThemePreset.light.spec.ink.hexString)
        #expect(model.page(page)?.elements.count == 1, "still on screen")
        #expect(model.saveProblem != nil)
        // A page operation would rewrite the manifest from disk without the
        // text — it must not run while the text is unsaved.
        await model.addPage(template: .grid)
        #expect(model.page(page)?.elements.count == 1)

        try setWritable(true, store.documentURL(for: id))
        await model.addPage(template: .grid)

        #expect(model.saveProblem == nil)
        let onDisk = try await store.manifest(for: id)
        #expect(onDisk.pages.first?.elements.first?.text == "Krebs cycle")
        #expect(onDisk.pages.count == 2)
    }

    @Test("Deleting pages offers an Undo that puts them all back in order")
    func undoDeletion() async throws {
        let (model, _, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.addPage(template: .grid)
        await model.addPage(template: .dotted)
        let pages = model.pages.map(\.id)

        await model.deletePages([pages[0], pages[2]])
        #expect(model.pages.map(\.id) == [pages[1]])
        #expect(model.recentlyDeletedPages == [pages[0], pages[2]])

        await model.undoRecentDeletion()
        #expect(model.pages.map(\.id) == pages)
        #expect(model.recentlyDeletedPages.isEmpty)
    }
}

@Suite("Page sync ledger")
struct PageSyncLedgerTests {
    @Test("Only changed positions are sent, and a shorter notebook still pushes")
    func changes() {
        let ledger = PageSyncLedger(accountID: "a").accepting(["p1", "p2", "p3"])
        #expect(!ledger.needsPush(["p1", "p2", "p3"]))
        #expect(ledger.changedIndices(["p1", "X", "p3"]) == [1])
        #expect(ledger.changedIndices(["p1", "p3"]) == [1], "a delete shifts what's at each position")
        #expect(ledger.needsPush(["p1", "p2"]), "nothing changed, but a page went")
        #expect(ledger.changedIndices(["p1", "p2", "p3", "p4"]) == [3])
    }

    @Test("A ledger from another account is not trusted")
    func accountScoped() {
        let notebook = UUID()
        PageSyncLedger(accountID: "a").accepting(["x"]).save(notebook: notebook)
        defer { try? FileManager.default.removeItem(at: PageSyncLedger.url(for: notebook)) }
        #expect(PageSyncLedger.load(notebook: notebook, accountID: "a").pageCount == 1)
        #expect(PageSyncLedger.load(notebook: notebook, accountID: "b").pageCount == 0)
    }

    @Test("An ink fingerprint changes when the ink does, and only then")
    func inkFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-fp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        let page = try await store.createDocument(id: id, firstPageTemplate: .blank).pages[0].id
        #expect(await store.inkFingerprint(notebook: id, page: page) == "none")
        try await store.savePageData(Data("one".utf8), notebook: id, page: page)
        let first = await store.inkFingerprint(notebook: id, page: page)
        #expect(await store.inkFingerprint(notebook: id, page: page) == first)
        try await store.savePageData(Data("two!".utf8), notebook: id, page: page)
        #expect(await store.inkFingerprint(notebook: id, page: page) != first)
    }
}
