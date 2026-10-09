import ClassMateTheme
import Foundation
import NotesModels
import SwiftData
import Testing
@testable import NotesServices

/// Two devices and the iCloud folder between them, as real libraries: a store,
/// a database and a sync each, sharing one folder (`FolderDrive`). Every rule
/// of D-003 is played out here end to end, because the one thing that can't
/// be checked without two iPads is iCloud carrying the files, not what the app
/// does with them.
@MainActor
@Suite("iCloud sync between two devices", .serialized)
struct CloudSyncTests {

    struct Device {
        let store: DocumentStore
        let container: ModelContainer
        let repository: NotebookRepository
        let sync: CloudSyncController
        let root: URL
    }

    struct World {
        let shared: URL
        let a: Device
        let b: Device
        let base: URL

        func cleanUp() { try? FileManager.default.removeItem(at: base) }
    }

    private func device(_ name: String, base: URL, shared: URL) -> Device {
        let root = base.appendingPathComponent(name, isDirectory: true)
        let store = DocumentStore(rootURL: root.appendingPathComponent("Notebooks", isDirectory: true))
        let container = ModelContainerFactory.make(inMemory: true)
        let repository = NotebookRepository(
            context: container.mainContext, store: store, entitlements: EntitlementService(listenForUpdates: false)
        )
        let defaults = UserDefaults(suiteName: "cloud-sync-\(UUID().uuidString)")!
        defaults.set(true, forKey: "cloudSync.enabled.v1")
        let sync = CloudSyncController(
            store: store, repository: repository, drive: FolderDrive(root: shared),
            stateFolder: root.appendingPathComponent("CloudSync", isDirectory: true), defaults: defaults,
            supported: true
        )
        return Device(store: store, container: container, repository: repository, sync: sync, root: root)
    }

    private func world() -> World {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-cloud-\(UUID().uuidString)", isDirectory: true)
        let shared = base.appendingPathComponent("iCloud/Notebooks", isDirectory: true)
        return World(shared: shared, a: device("A", base: base, shared: shared), b: device("B", base: base, shared: shared), base: base)
    }

    private func notebook(on device: Device, _ title: String) async throws -> Notebook {
        let notebook = try await device.repository.create(
            title: title, coverColor: ThemePreset.light.accent, style: PageStyle(template: .ruled), showsCover: false
        )
        await device.repository.mirrorInfo([notebook])
        return notebook
    }

    private func firstPage(_ id: UUID, on device: Device) async throws -> UUID {
        try #require(try await device.store.manifest(for: id).pages.first?.id)
    }

    private func write(_ ink: String, to id: UUID, on device: Device) async throws {
        try await device.store.savePageData(Data(ink.utf8), notebook: id, page: try await firstPage(id, on: device))
    }

    private func ink(_ id: UUID, on device: Device) async throws -> String? {
        let page = try await firstPage(id, on: device)
        return await device.store.pageData(notebook: id, page: page).map { String(decoding: $0, as: UTF8.self) }
    }

    private func rows(on device: Device) throws -> [Notebook] {
        try device.container.mainContext.fetch(FetchDescriptor<Notebook>())
    }

    // MARK: -

    @Test("A notebook made on one device appears on the other, with its name and its ink")
    func newNotebookTravels() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Biology")
        try await write("cells", to: made.id, on: world.a)

        await world.a.sync.syncNow()
        await world.b.sync.syncNow()

        let arrived = try #require(try rows(on: world.b).first { $0.id == made.id })
        #expect(arrived.title == "Biology")
        #expect(try await ink(made.id, on: world.b) == "cells")
        #expect(world.b.sync.status != .unavailable)
    }

    @Test("Ink added on one device reaches the other, and what it replaced is kept")
    func editTravels() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Physics")
        try await write("v1", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()

        try await write("v2", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()

        #expect(try await ink(made.id, on: world.b) == "v2")
        let kept = try FileManager.default.contentsOfDirectory(
            atPath: world.b.root.appendingPathComponent("CloudSync/Replaced").path
        )
        #expect(kept.count == 1, "the version replaced is kept whole")
    }

    @Test("Changed on both devices before they synced: both versions are kept, on both devices")
    func conflictKeepsBoth() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "History")
        try await write("start", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()

        try await write("from A", to: made.id, on: world.a)
        try await write("from B", to: made.id, on: world.b)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()
        await world.a.sync.syncNow()

        for device in [world.a, world.b] {
            var inks: Set<String> = []
            for row in try rows(on: device) { if let value = try await ink(row.id, on: device) { inks.insert(value) } }
            #expect(inks == ["from A", "from B"], "neither device lost either version")
            #expect(try rows(on: device).contains { $0.title == "History" + NotebookSync.otherDeviceSuffix })
        }
    }

    @Test("A notebook open in the editor is never replaced; it syncs once it closes")
    func openNotebookIsLeftAlone() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Maths")
        try await write("v1", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()

        await world.b.store.beginEditing(made.id)
        try await write("v2", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()
        #expect(try await ink(made.id, on: world.b) == "v1", "not under the open editor")

        await world.b.store.endEditing(made.id)
        await world.b.sync.syncNow()
        #expect(try await ink(made.id, on: world.b) == "v2")
    }

    @Test("A rename travels, and an older rename never undoes a newer one")
    func renamesNewestWins() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Draft")
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()

        try world.a.repository.rename(made, to: "Chemistry")
        await world.a.repository.mirrorInfo([made])
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()
        let onB = try #require(try rows(on: world.b).first { $0.id == made.id })
        #expect(onB.title == "Chemistry")

        // B renames later; A then changes the ink. A's push must not carry
        // its older title back over B's.
        try await Task.sleep(for: .milliseconds(1100))
        try world.b.repository.rename(onB, to: "Organic Chemistry")
        await world.b.repository.mirrorInfo([onB])
        try await write("ink from A", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()
        await world.a.sync.syncNow()

        #expect(try rows(on: world.a).first { $0.id == made.id }?.title == "Organic Chemistry")
        #expect(try rows(on: world.b).first { $0.id == made.id }?.title == "Organic Chemistry")
        #expect(try await ink(made.id, on: world.b) == "ink from A")
    }

    @Test("Trashed on one device is trashed on the other; deleting for good there only trashes it here")
    func deletionsAreSoft() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Old notes")
        try await write("keep me", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()

        try world.a.repository.moveToTrash(made)
        await world.a.repository.mirrorInfo([made])
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()
        #expect(try rows(on: world.b).first { $0.id == made.id }?.isTrashed == true)

        try await world.a.repository.purge(made)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()
        await world.b.sync.syncNow()
        let onB = try rows(on: world.b).first { $0.id == made.id }
        #expect(onB?.isTrashed == true, "still in B's trash, restorable")
        #expect(try await ink(made.id, on: world.b) == "keep me")
        #expect(!PackageFiles.packageIDs(in: world.shared).contains(made.id), "and it doesn't come back up")
    }

    @Test("Replaced copies are kept, but only the newest two of each notebook")
    func replacedCopiesAreCapped() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Busy")
        try await write("v0", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()
        for version in 1...4 {
            try await Task.sleep(for: .milliseconds(5))
            try await write("v\(version)", to: made.id, on: world.a)
            await world.a.sync.syncNow()
            await world.b.sync.syncNow()
        }
        let kept = try FileManager.default.contentsOfDirectory(
            atPath: world.b.root.appendingPathComponent("CloudSync/Replaced").path
        )
        #expect(kept.count == NotebookSync.copiesKept)
        #expect(try await ink(made.id, on: world.b) == "v4")
    }

    @Test("A damaged copy in iCloud is refused; the notebook here is untouched")
    func damagedCopyRefused() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Art")
        try await write("sketch", to: made.id, on: world.a)
        await world.a.sync.syncNow()
        await world.b.sync.syncNow()

        let manifest = world.shared.appendingPathComponent("\(made.id.uuidString).cmnote/manifest.json")
        try Data("{ not a manifest".utf8).write(to: manifest)
        await world.b.sync.syncNow()

        #expect(try await ink(made.id, on: world.b) == "sketch")
        if case .partly(let failed, _) = world.b.sync.status { #expect(failed == 1) } else {
            Issue.record("a refused copy is reported")
        }
    }

    @Test("Only the notebook travels: this device's search index and recovery copies stay here")
    func localFilesStay() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Index")
        try await write("words", to: made.id, on: world.a)
        try await world.a.store.saveSearchIndex(SearchIndex(), for: made.id)
        _ = try await world.a.store.addPage(to: made.id, style: PageStyle(template: .ruled)) // writes a backup
        await world.a.sync.syncNow()

        let files = PackageFiles.syncedFiles(in: world.shared.appendingPathComponent("\(made.id.uuidString).cmnote"))
        #expect(files.contains("manifest.json"))
        #expect(!files.contains("search.json"))
        #expect(!files.contains("manifest.backup.json"))
        let all = try FileManager.default.contentsOfDirectory(
            atPath: world.shared.appendingPathComponent("\(made.id.uuidString).cmnote").path
        )
        #expect(!all.contains("search.json") && !all.contains("manifest.backup.json"))
    }

    @Test("Writing one page uploads that page, not the notebook")
    func onlyChangesAreWritten() async throws {
        let world = world()
        defer { world.cleanUp() }
        let made = try await notebook(on: world.a, "Long")
        _ = try await world.a.store.addPage(to: made.id, style: PageStyle(template: .ruled))
        let pages = try await world.a.store.manifest(for: made.id).pages.map(\.id)
        try await world.a.store.savePageData(Data("one".utf8), notebook: made.id, page: pages[0])
        try await world.a.store.savePageData(Data("two".utf8), notebook: made.id, page: pages[1])
        await world.a.sync.syncNow()
        let untouched = world.shared.appendingPathComponent("\(made.id.uuidString).cmnote/pages/\(pages[1].uuidString).drawing")
        let before = try FileManager.default.attributesOfItem(atPath: untouched.path)[.modificationDate] as? Date

        try await Task.sleep(for: .milliseconds(1100))
        try await world.a.store.savePageData(Data("one, more".utf8), notebook: made.id, page: pages[0])
        await world.a.sync.syncNow()
        let after = try FileManager.default.attributesOfItem(atPath: untouched.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test("The fingerprint is the content: equal on two copies, blind to dates and this device's files")
    func fingerprint() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cmnotes-fp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let one = base.appendingPathComponent("one.cmnote"), two = base.appendingPathComponent("two.cmnote")
        for folder in [one, two] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("pages"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("ink".utf8).write(to: folder.appendingPathComponent("pages/a.drawing"))
        }
        try Data("derived".utf8).write(to: two.appendingPathComponent("search.json"))
        try Data(#"{"title":"x"}"#.utf8).write(to: two.appendingPathComponent("info.json"))
        #expect(PackageFiles.fingerprint(of: one) == PackageFiles.fingerprint(of: two))
        try Data("more ink".utf8).write(to: two.appendingPathComponent("pages/a.drawing"))
        #expect(PackageFiles.fingerprint(of: one) != PackageFiles.fingerprint(of: two))
    }

    @Test("A build without the iCloud container never syncs, whatever was saved")
    func unsupportedBuildNeverSyncs() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cmnotes-unsupported-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = DocumentStore(rootURL: base.appendingPathComponent("Notebooks"))
        let container = ModelContainerFactory.make(inMemory: true)
        let repository = NotebookRepository(
            context: container.mainContext, store: store, entitlements: EntitlementService(listenForUpdates: false)
        )
        let defaults = UserDefaults(suiteName: "cloud-unsupported-\(UUID().uuidString)")!
        defaults.set(true, forKey: "cloudSync.enabled.v1")
        let sync = CloudSyncController(
            store: store, repository: repository, drive: FolderDrive(root: base.appendingPathComponent("iCloud")),
            stateFolder: base.appendingPathComponent("state"), defaults: defaults, supported: false
        )
        #expect(!sync.isEnabled)
        sync.setEnabled(true)
        #expect(!sync.isEnabled)
    }

    @Test("Off means off: nothing is read or written")
    func offIsOff() async throws {
        let world = world()
        defer { world.cleanUp() }
        _ = try await notebook(on: world.a, "Private")
        world.a.sync.setEnabled(false)
        await world.a.sync.syncNow()
        #expect(PackageFiles.packageIDs(in: world.shared).isEmpty)
        #expect(world.a.sync.status == .off)
    }
}
