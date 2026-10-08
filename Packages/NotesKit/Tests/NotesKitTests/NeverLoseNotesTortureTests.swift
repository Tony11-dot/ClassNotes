import Foundation
import NotesModels
import Testing
@testable import NotesServices

/// A deterministic generator, so a failing run can be replayed from its seed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Thousands of random document operations, interleaved with crashes, cut-off
/// writes and damaged manifests, checked after every single step against a
/// model of what the user did. The one rule: ink that reached disk is never
/// lost — it is on its page, or in Recently Deleted with every stroke — and a
/// page that was deleted stays deleted unless damage forced a step back.
@Suite("Never lose notes: torture")
struct NeverLoseNotesTortureTests {

    /// What the user did, independent of the store.
    private struct Model {
        var live: [UUID] = []
        /// The newest ink that reached disk, for live AND deleted pages.
        var ink: [UUID: Data] = [:]
        /// Ink staged by a save that hasn't written yet. A crash loses it — it
        /// was never on disk — but until then the page must show it.
        var staged: [UUID: (data: Data, stamp: PageInkJournal.Stamp)] = [:]
        /// Deleted pages in the order they were deleted, with the index each
        /// was deleted from. An array, not a dictionary: a seed must replay
        /// the same run, and dictionary order changes from process to process.
        var trashed: [(id: UUID, index: Int)] = []
        var elements: [UUID: [UUID]] = [:]
        /// Every page id the store has ever handed out — anything else showing
        /// up in the manifest is a phantom.
        var known: Set<UUID> = []
        /// Pages deleted by THIS store instance: a stale canvas can still save
        /// to these (the in-session tombstone), never across a relaunch.
        var tombstoned: Set<UUID> = []
        /// Destroyed for good. Showing up again anywhere is a resurrection.
        var purged: Set<UUID> = []

        func visible(_ page: UUID) -> Data? { staged[page]?.data ?? ink[page] }
        func isTrashed(_ page: UUID) -> Bool { trashed.contains { $0.id == page } }
        mutating func untrash(_ page: UUID) { trashed.removeAll { $0.id == page } }
        /// The first live page with a pending save, in page order.
        var firstStaged: UUID? { live.first { staged[$0] != nil } }
    }

    private enum Damage: CaseIterable { case garbage, truncated, missing }

    @Test("Random edits, crashes and damage never lose committed ink", arguments: [1, 2, 3, 4] as [UInt64])
    func torture(seed: UInt64) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-torture-\(seed)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var rng = SplitMix64(state: seed)
        var store = DocumentStore(rootURL: root)
        let id = UUID()
        var model = Model()
        let created = try await store.createDocument(id: id, style: PageStyle(template: .ruled), pageCount: 3)
        model.live = created.pages.map(\.id)
        model.known.formUnion(model.live)
        var counts: [String: Int] = [:]

        for step in 0..<750 {
            let roll = Int.random(in: 0..<100, using: &rng)
            let page = model.live.randomElement(using: &rng)!
            let bytes = Data("ink \(seed)-\(step)-\(page.uuidString.prefix(4))".utf8)
            var damaged = false
            let op: String

            switch roll {
            case 0..<26:
                op = "write"
                try await store.savePageData(bytes, notebook: id, page: page)
                model.ink[page] = bytes
                model.staged[page] = nil

            case 26..<31:
                // A slow save finishing after a newer one must not win.
                op = "stale write"
                let older = store.journal.stamp()
                let newer = store.journal.stamp()
                try await store.savePageData(bytes, notebook: id, page: page, stamp: newer)
                try await store.savePageData(Data("stale".utf8), notebook: id, page: page, stamp: older)
                model.ink[page] = bytes
                model.staged[page] = nil

            case 31..<38:
                op = "stage"
                let stamp = store.journal.stamp()
                store.journal.stage(bytes, page: page, stamp: stamp)
                model.staged[page] = (bytes, stamp)

            case 38..<42:
                op = "finish staged"
                guard let target = model.firstStaged, let pending = model.staged[target] else { continue }
                try await store.savePageData(pending.data, notebook: id, page: target, stamp: pending.stamp)
                model.ink[target] = pending.data
                model.staged[target] = nil

            case 42..<50:
                op = "insert"
                guard model.live.count < 24 else { continue }
                let index = Int.random(in: 0...model.live.count, using: &rng)
                let inserted = try await store.insertPage(
                    notebook: id, at: index, style: PageStyle(template: .grid)
                ).page
                model.live.insert(inserted.id, at: index)
                model.known.insert(inserted.id)

            case 50..<58:
                op = "delete"
                let index = model.live.firstIndex(of: page)!
                let after = try await store.deletePage(notebook: id, page: page)
                model.live.remove(at: index)
                model.untrash(page)
                model.trashed.append((page, index))
                model.tombstoned.insert(page)
                if let pending = model.staged.removeValue(forKey: page) { model.ink[page] = pending.data }
                if model.live.isEmpty {
                    // The last page is never deleted out from under the user;
                    // the store hands back a fresh blank one.
                    model.live = after.pages.map(\.id)
                    model.known.formUnion(model.live)
                }

            case 58..<61:
                // The canvas of a page deleted a moment ago flushes as it's torn down.
                op = "late save"
                guard let target = model.trashed.first(where: { model.tombstoned.contains($0.id) })?.id else { continue }
                try await store.savePageData(bytes, notebook: id, page: target)
                model.ink[target] = bytes

            case 61..<67:
                op = "restore"
                guard let (target, index) = model.trashed.randomElement(using: &rng) else { continue }
                try await store.restorePage(notebook: id, page: target)
                model.live.insert(target, at: min(index, model.live.count))
                model.untrash(target)
                model.tombstoned.remove(target)

            case 67..<71:
                op = "move"
                let from = Int.random(in: 0..<model.live.count, using: &rng)
                let to = Int.random(in: 0..<model.live.count, using: &rng)
                try await store.movePage(notebook: id, from: from, to: to)
                let moved = model.live.remove(at: from)
                model.live.insert(moved, at: max(0, min(to, model.live.count)))

            case 71..<75:
                op = "duplicate"
                guard model.live.count < 24 else { continue }
                let after = try await store.duplicatePage(notebook: id, page: page)
                let index = model.live.firstIndex(of: page)!
                let copy = after.pages[index + 1].id
                model.live.insert(copy, at: index + 1)
                model.known.insert(copy)
                model.ink[copy] = model.visible(page)
                model.elements[copy] = model.elements[page]

            case 75..<81:
                op = "elements"
                let element = PageElement(kind: .text, x: 20, y: 20, width: 120, height: 40, text: "step \(step)")
                try await store.setElements([element], notebook: id, page: page)
                model.elements[page] = [element.id]

            case 81..<89:
                op = "crash"
                store = DocumentStore(rootURL: root)
                model.staged.removeAll()
                model.tombstoned.removeAll()

            case 89..<92:
                // The process died between keeping the backup and writing the
                // new manifest.
                op = "cut-off write"
                _ = Darwin.rename(
                    await store.manifestURL(for: id).path,
                    await store.manifestBackupURL(for: id).path
                )
                store = DocumentStore(rootURL: root)
                model.staged.removeAll()
                model.tombstoned.removeAll()

            case 92..<96:
                let damage = Damage.allCases.randomElement(using: &rng)!
                op = "damage \(damage)"
                let url = await store.manifestURL(for: id)
                switch damage {
                case .garbage: try Data("{\"pages\": [ nonsense".utf8).write(to: url)
                case .truncated:
                    let data = try Data(contentsOf: url)
                    try data.prefix(data.count / 2).write(to: url)
                case .missing: try FileManager.default.removeItem(at: url)
                }
                if Bool.random(using: &rng) {
                    store = DocumentStore(rootURL: root)
                    model.staged.removeAll()
                    model.tombstoned.removeAll()
                }
                damaged = true

            default:
                op = "purge"
                guard let target = model.trashed.randomElement(using: &rng)?.id else { continue }
                try await store.purgePages([target], notebook: id)
                model.untrash(target)
                model.purged.insert(target)
                model.ink[target] = nil
                model.elements[target] = nil
            }
            counts[op, default: 0] += 1

            try await check(store: store, notebook: id, model: &model, damaged: damaged, context: "seed \(seed) step \(step) \(op)")
        }

        // The whole run, replayed into a store that has never seen it.
        try await check(store: DocumentStore(rootURL: root), notebook: id, model: &model, damaged: false, context: "seed \(seed) final")
        print("TORTURE seed=\(seed) steps=750 ops=\(counts.sorted { $0.key < $1.key })")
    }

    /// Every invariant, against the store as it stands.
    private func check(
        store: DocumentStore, notebook id: UUID, model: inout Model, damaged: Bool, context: String
    ) async throws {
        let manifest = try await store.manifest(for: id)
        let ids = manifest.pages.map(\.id)
        #expect(Set(ids).count == ids.count, "a page listed twice — \(context)")
        #expect(model.purged.isDisjoint(with: ids), "a purged page came back — \(context)")
        for page in ids where !model.known.contains(page) {
            // The one new page allowed: the blank page a notebook rebuilt from
            // nothing is given so it has somewhere to write.
            let isRebuildBlank = damaged && ids.count == 1
            #expect(isRebuildBlank, "a page the user never made — \(context)")
            #expect(await store.pageData(notebook: id, page: page) == nil, "ink on a phantom — \(context)")
            model.known.insert(page)
        }

        if damaged {
            // Damage may cost the LAST manifest step (that's what the backup
            // is), never ink. Take the store's page list from here on.
            for page in ids where model.isTrashed(page) {
                model.untrash(page)
                model.tombstoned.remove(page)
            }
            for page in model.live where !ids.contains(page) && !model.isTrashed(page) {
                // Only ink still pending in memory may be missing from the
                // rebuilt list: it becomes a page again the moment it's written.
                #expect(model.ink[page] == nil, "a page with ink vanished after damage — \(context)")
                model.ink[page] = nil
                model.staged[page] = nil
            }
            model.live = ids
            for page in manifest.pages { model.elements[page.id] = page.elements.map(\.id) }
        } else {
            #expect(ids == model.live, "page order — \(context)")
            for page in manifest.pages {
                #expect(page.elements.map(\.id) == (model.elements[page.id] ?? []), "elements — \(context)")
            }
        }

        for page in ids {
            let onPage = await store.pageData(notebook: id, page: page)
            #expect(onPage == model.visible(page), "ink on a live page — \(context)")
        }

        let trashedIDs = Set(await store.trashedPages(notebook: id).map(\.id))
        #expect(trashedIDs == Set(model.trashed.map(\.id)), "Recently Deleted — \(context)")
        for page in model.trashed.map(\.id) {
            let url = await store.trashedPageURL(notebook: id, page: page)
            let kept = try? Data(contentsOf: url)
            #expect(kept == model.ink[page], "ink of a deleted page — \(context)")
        }
    }
}
