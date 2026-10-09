import ClassMateTheme
import Foundation
import NotesModels
import SwiftData
import Testing
@testable import NotesServices

private struct SyncSplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Two devices writing, opening, closing and syncing in random order (seeded,
/// replayable). The rules, checked at the end:
/// - the two libraries converge: the same notebooks with the same ink;
/// - nothing is lost: every page a device wrote is still somewhere on BOTH,
///   unless a device that could see it wrote over it.
@MainActor
@Suite("iCloud sync: torture", .serialized)
struct CloudSyncTortureTests {

    private struct Device {
        let store: DocumentStore
        let container: ModelContainer
        let repository: NotebookRepository
        let sync: CloudSyncController
    }

    private func device(_ name: String, base: URL, shared: URL) -> Device {
        let root = base.appendingPathComponent(name, isDirectory: true)
        let store = DocumentStore(rootURL: root.appendingPathComponent("Notebooks", isDirectory: true))
        let container = ModelContainerFactory.make(inMemory: true)
        let repository = NotebookRepository(
            context: container.mainContext, store: store, entitlements: EntitlementService(listenForUpdates: false)
        )
        let defaults = UserDefaults(suiteName: "cloud-torture-\(UUID().uuidString)")!
        defaults.set(true, forKey: "cloudSync.enabled.v1")
        let sync = CloudSyncController(
            store: store, repository: repository, drive: FolderDrive(root: shared),
            stateFolder: root.appendingPathComponent("CloudSync", isDirectory: true), defaults: defaults,
            supported: true
        )
        return Device(store: store, container: container, repository: repository, sync: sync)
    }

    private func liveIDs(_ device: Device) throws -> [UUID] {
        try device.container.mainContext.fetch(FetchDescriptor<Notebook>())
            .filter { !$0.isTrashed }.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }

    private func ink(_ id: UUID, on device: Device) async -> String? {
        guard let page = try? await device.store.manifest(for: id).pages.first?.id else { return nil }
        return await device.store.pageData(notebook: id, page: page).map { String(decoding: $0, as: UTF8.self) }
    }

    private func library(_ device: Device) async throws -> [UUID: String] {
        var result: [UUID: String] = [:]
        for id in try liveIDs(device) { result[id] = await ink(id, on: device) ?? "" }
        return result
    }

    @Test("Random writes, opens and syncs on two devices converge and lose nothing", arguments: [11, 12, 13] as [UInt64])
    func torture(seed: UInt64) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-cloud-torture-\(seed)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let shared = base.appendingPathComponent("iCloud/Notebooks", isDirectory: true)
        let devices = [device("A", base: base, shared: shared), device("B", base: base, shared: shared)]
        var rng = SyncSplitMix(state: seed)
        var alive: Set<String> = []
        var open: [Int: Set<UUID>] = [0: [], 1: []]
        var counts: [String: Int] = [:]

        for step in 0..<220 {
            let which = Int.random(in: 0...1, using: &rng)
            let device = devices[which]
            let ids = try liveIDs(device)
            let roll = Int.random(in: 0..<100, using: &rng)
            let op: String
            switch roll {
            case 0..<12:
                op = "create"
                let made = try await device.repository.create(
                    title: "N\(step)", coverColor: ThemePreset.light.accent,
                    style: PageStyle(template: .ruled), showsCover: false
                )
                await device.repository.mirrorInfo([made])
                let value = "\(which)-\(step)"
                let page = try #require(try await device.store.manifest(for: made.id).pages.first?.id)
                try await device.store.savePageData(Data(value.utf8), notebook: made.id, page: page)
                alive.insert(value)
            case 12..<52:
                op = "write"
                guard let id = ids.randomElement(using: &rng),
                      let page = try? await device.store.manifest(for: id).pages.first?.id else { continue }
                // Whatever this device shows on the page now, it has seen: writing
                // over it is the user's own doing.
                if let seen = await ink(id, on: device) { alive.remove(seen) }
                let value = "\(which)-\(step)"
                try await device.store.savePageData(Data(value.utf8), notebook: id, page: page)
                alive.insert(value)
            case 52..<62:
                op = "open/close"
                guard let id = ids.randomElement(using: &rng) else { continue }
                if open[which]!.contains(id) {
                    await device.store.endEditing(id)
                    open[which]!.remove(id)
                } else {
                    await device.store.beginEditing(id)
                    open[which]!.insert(id)
                }
            default:
                op = "sync"
                await device.sync.syncNow()
            }
            counts[op, default: 0] += 1
        }

        // Everything closes; sync until the two agree.
        for (index, device) in devices.enumerated() {
            for id in open[index]! { await device.store.endEditing(id) }
        }
        var agreed = false
        for _ in 0..<6 {
            await devices[0].sync.syncNow()
            await devices[1].sync.syncNow()
            if try await library(devices[0]) == library(devices[1]) {
                agreed = true
                break
            }
        }
        let a = try await library(devices[0]), b = try await library(devices[1])
        #expect(agreed, "the two libraries converge — seed \(seed)")
        #expect(alive.isSubset(of: Set(a.values)), "nothing written is lost on A — seed \(seed): missing \(alive.subtracting(a.values))")
        #expect(alive.isSubset(of: Set(b.values)), "nothing written is lost on B — seed \(seed): missing \(alive.subtracting(b.values))")
        print("CLOUD TORTURE seed=\(seed) notebooks=\(a.count) alive=\(alive.count) ops=\(counts.sorted { $0.key < $1.key })")
    }
}
