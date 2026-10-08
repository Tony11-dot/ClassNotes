import Foundation
import NotesModels
import PencilKit
import Testing
@testable import NotesEditor
@testable import NotesServices

/// The three promises the writing surface makes: what you write stays written,
/// what you erase stays erased, and the lasso acts on exactly what you circled.

@Suite("Page ink reaches disk in the order it was drawn")
struct PageInkOrderingTests {
    private func makeStore() async throws -> (DocumentStore, UUID, UUID, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-ink-\(UUID().uuidString)", isDirectory: true)
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        let manifest = try await store.createDocument(id: id, firstPageTemplate: .blank)
        return (store, id, manifest.pages[0].id, root)
    }

    @Test("A slow save of an older snapshot never lands on top of a newer one")
    func staleSaveIsDropped() async throws {
        let (store, id, page, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // The debounced save read the page BEFORE the erase…
        let older = store.journal.stamp()
        // …the flush on leaving the editor read it AFTER, and got there first.
        let newer = store.journal.stamp()
        try await store.savePageData(Data("after erase".utf8), notebook: id, page: page, stamp: newer)
        try await store.savePageData(Data("before erase".utf8), notebook: id, page: page, stamp: older)

        let onDisk = await store.pageData(notebook: id, page: page)
        #expect(onDisk == Data("after erase".utf8), "erased ink must not come back")
    }

    @Test("A page reopened before its save lands reads the newest ink, not the file")
    func stagedInkIsReadFirst() async throws {
        let (store, id, page, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.savePageData(Data("old".utf8), notebook: id, page: page)

        let stamp = store.journal.stamp()
        store.journal.stage(Data("just written".utf8), page: page, stamp: stamp)
        #expect(await store.pageData(notebook: id, page: page) == Data("just written".utf8))

        try await store.savePageData(Data("just written".utf8), notebook: id, page: page, stamp: stamp)
        #expect(store.journal.pending(page: page) == nil, "staged bytes are let go once written")
        #expect(await store.pageData(notebook: id, page: page) == Data("just written".utf8))
    }

    @Test("Staging an older snapshot never replaces a newer one")
    func olderStageIgnored() {
        let journal = PageInkJournal()
        let page = UUID()
        let older = journal.stamp()
        let newer = journal.stamp()
        journal.stage(Data("new".utf8), page: page, stamp: newer)
        journal.stage(Data("old".utf8), page: page, stamp: older)
        #expect(journal.pending(page: page) == Data("new".utf8))
    }

    @Test("An unreadable page is set aside, never overwritten — and never adopted as a page")
    func unreadablePageIsQuarantined() async throws {
        let (store, id, page, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = Data("not a drawing".utf8)
        try await store.savePageData(garbage, notebook: id, page: page)

        await store.quarantinePageData(notebook: id, page: page)

        #expect(await store.pageData(notebook: id, page: page) == nil)
        let kept = store.documentURL(for: id)
            .appendingPathComponent("pages/\(page.uuidString).drawing.unreadable")
        #expect(try Data(contentsOf: kept) == garbage)
        let manifest = try await store.manifest(for: id)
        #expect(manifest.pages.map(\.id) == [page], "the quarantined file is not a phantom page")
    }

    @Test("A deleted page's staged ink is forgotten")
    func deletedPageForgetsStagedInk() async throws {
        let (store, id, page, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.addPage(to: id, template: .blank)
        store.journal.stage(Data("ink".utf8), page: page, stamp: store.journal.stamp())

        try await store.deletePage(notebook: id, page: page)

        #expect(store.journal.pending(page: page) == nil)
        #expect(await store.pageData(notebook: id, page: page) == nil)
    }
}

@Suite("The lasso holds what it circled, not where it was")
struct LassoIdentityTests {
    private func stroke(x: CGFloat, created: Date) -> PKStroke {
        let points = (0...4).map { index in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(index) * 5, y: 20), timeOffset: Double(index) * 0.01,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: created)
        )
    }

    @Test("Ink landing before the selection doesn't redirect it")
    func survivesReindexing() {
        let a = stroke(x: 0, created: Date(timeIntervalSince1970: 1))
        let b = stroke(x: 100, created: Date(timeIntervalSince1970: 2))
        let keys = [StrokeKey(b)]

        let inserted = stroke(x: 300, created: Date(timeIntervalSince1970: 3))
        let indices = StrokeKey.indices(of: keys, in: [inserted, a, b])
        #expect(indices == [2], "still the stroke that was circled, at its new position")
    }

    @Test("A stroke erased since is skipped, never substituted")
    func erasedStrokeIsSkipped() {
        let a = stroke(x: 0, created: Date(timeIntervalSince1970: 1))
        let b = stroke(x: 100, created: Date(timeIntervalSince1970: 2))
        #expect(StrokeKey.indices(of: [StrokeKey(b)], in: [a]).isEmpty)
    }

    @Test("A moved stroke is a different placement, so the selection re-keys")
    func moveChangesKey() {
        let a = stroke(x: 0, created: Date(timeIntervalSince1970: 1))
        var moved = a
        moved.transform = CGAffineTransform(translationX: 24, y: 24)
        #expect(StrokeKey(a) != StrokeKey(moved))
        #expect(StrokeKey.indices(of: [StrokeKey(moved)], in: [a, moved]) == [1])
    }

    @Test("Identical strokes each claim their own match")
    func duplicatesClaimDistinctStrokes() {
        let a = stroke(x: 0, created: Date(timeIntervalSince1970: 1))
        #expect(StrokeKey.indices(of: [StrokeKey(a), StrokeKey(a)], in: [a, a, a]) == [0, 1])
    }
}

@Suite("Scribble-erase only takes what it covers")
struct ScribbleCoverageTests {
    /// Five sweeps across a 100 × 40 band.
    private var scrub: [CGPoint] {
        (0..<5).flatMap { sweep in
            (0...10).map { step -> CGPoint in
                let t = Double(sweep % 2 == 0 ? step : 10 - step) / 10
                return CGPoint(x: t * 100, y: 20 + Double(sweep) * 10)
            }
        }
    }

    @Test("The word scrubbed out is erased")
    func erasesTheWord() {
        let word = (0...10).map { CGPoint(x: 10 + Double($0) * 8, y: 40) }
        #expect(ScribbleDetector.erases(scrub, word, tolerance: 12))
    }

    @Test("A long underline the scrub only grazes survives")
    func grazedUnderlineSurvives() {
        let underline = (0...40).map { CGPoint(x: -100 + Double($0) * 10, y: 66) }
        #expect(ScribbleDetector.crosses(scrub, underline, tolerance: 12), "it does touch")
        #expect(!ScribbleDetector.erases(scrub, underline, tolerance: 12), "but it was not scrubbed")
    }
}
