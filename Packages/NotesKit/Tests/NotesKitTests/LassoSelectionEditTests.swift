import CoreGraphics
import Foundation
import NotesEditor
import NotesModels
import NotesServices
import Testing

/// What a lasso does to everything it is holding — delete, move, resize,
/// duplicate — done to the WHOLE selection in one write.
///
/// Each of these used to be a loop over the single-element mutators, and each
/// of those ends in `DocumentStore.setElements`, which re-reads the manifest,
/// re-encodes all of it and writes it atomically. Dragging a selection of a
/// dozen photos was therefore a dozen sequential whole-manifest rewrites on one
/// drag release, eleven of which were immediately thrown away. The point of
/// these tests is that doing it in one pass gives the SAME answer — the saving
/// is only worth having if the result is identical.
@MainActor
@Suite("A lasso edits everything it holds at once")
struct LassoSelectionEditTests {
    private func makeModel() async throws -> (NotebookEditorModel, UUID, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-lasso-\(UUID().uuidString)", isDirectory: true)
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .blank)
        let model = NotebookEditorModel(notebookID: id, store: store)
        await model.load()
        return (model, id, root)
    }

    /// Three images in a row, so a test can take some and leave others.
    private func seedImages(
        _ model: NotebookEditorModel, on pageID: UUID, count: Int
    ) async -> [UUID] {
        for index in 0..<count {
            await model.insertImage(
                Data("img\(index)".utf8), fileExtension: "png",
                frame: CGRect(x: 100 * Double(index), y: 50, width: 60, height: 40),
                on: pageID
            )
        }
        return (model.page(pageID)?.elements ?? []).map(\.id)
    }

    @Test("Deleting a selection takes exactly what it held, and nothing else")
    func deletesOnlyTheSelection() async throws {
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        let ids = await seedImages(model, on: pageID, count: 3)

        await model.deleteElements([ids[0], ids[2]], on: pageID)

        let left = (model.page(pageID)?.elements ?? []).map(\.id)
        #expect(left == [ids[1]])
    }

    @Test("Deleting nothing is not a write, and changes nothing")
    func deletingNothingIsHarmless() async throws {
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        let ids = await seedImages(model, on: pageID, count: 2)

        await model.deleteElements([], on: pageID)
        await model.deleteElements([UUID()], on: pageID) // names nothing on this page

        #expect((model.page(pageID)?.elements ?? []).map(\.id) == ids)
    }

    @Test("A moved selection takes its FILL PATHS with it, not just its frames")
    func moveCarriesPathsAlong() async throws {
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        // A fill is drawn from its own point list in page space, so moving the
        // frame without the points leaves the colour behind.
        await model.insertFill(
            outline: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 60)],
            holes: [[CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 20), CGPoint(x: 30, y: 30)]],
            colorHex: "#2266DD", on: pageID
        )
        let fillID = try #require(model.page(pageID)?.elements.first?.id)

        await model.moveElements([fillID], on: pageID, by: CGSize(width: 15, height: -5))

        let moved = try #require(model.page(pageID)?.elements.first { $0.id == fillID })
        #expect(moved.x == 25 ? true : false)
        #expect(moved.y == 5 ? true : false)
        #expect(moved.points.first?.x == 25 ? true : false)
        #expect(moved.points.first?.y == 5 ? true : false)
        #expect(moved.holes.first?.first?.x == 35 ? true : false)
        #expect(moved.holes.first?.first?.y == 15 ? true : false)
    }

    @Test("Moving the whole selection at once equals moving each one by one")
    func batchMoveMatchesOneByOne() async throws {
        let (batch, _, batchRoot) = try await makeModel()
        let (single, _, singleRoot) = try await makeModel()
        defer {
            try? FileManager.default.removeItem(at: batchRoot)
            try? FileManager.default.removeItem(at: singleRoot)
        }
        let batchPage = try #require(batch.pages.first?.id)
        let singlePage = try #require(single.pages.first?.id)
        let batchIDs = await seedImages(batch, on: batchPage, count: 3)
        let singleIDs = await seedImages(single, on: singlePage, count: 3)
        let offset = CGSize(width: 24, height: -12)

        await batch.moveElements(batchIDs, on: batchPage, by: offset)
        for id in singleIDs { await single.moveElement(id, on: singlePage, by: offset) }

        let a = (batch.page(batchPage)?.elements ?? []).map { CGPoint(x: $0.x, y: $0.y) }
        let b = (single.page(singlePage)?.elements ?? []).map { CGPoint(x: $0.x, y: $0.y) }
        #expect(a == b)
    }

    @Test("A resized selection scales frames and the paths inside them")
    func resizeScalesEverything() async throws {
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        await model.insertImage(
            Data("i".utf8), fileExtension: "png",
            frame: CGRect(x: 100, y: 100, width: 50, height: 40), on: pageID
        )
        let id = try #require(model.page(pageID)?.elements.first?.id)

        // Double about the origin, the way a corner handle anchored top-left does.
        await model.transformElements(
            [id], on: pageID,
            by: CGAffineTransform(translationX: -100, y: -100)
                .concatenating(CGAffineTransform(scaleX: 2, y: 2))
                .concatenating(CGAffineTransform(translationX: 100, y: 100))
        )

        let scaled = try #require(model.page(pageID)?.elements.first { $0.id == id })
        #expect(scaled.x == 100 ? true : false)
        #expect(scaled.y == 100 ? true : false)
        #expect(scaled.width == 100 ? true : false)
        #expect(scaled.height == 80 ? true : false)
    }

    @Test("Duplicate hands back the new ids, in the order they were asked for")
    func duplicateReturnsItsNewIDs() async throws {
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        let ids = await seedImages(model, on: pageID, count: 3)

        // Reversed, to prove the answer follows the REQUEST order rather than
        // whatever order the copies happen to land in on the page — the caller
        // selects what it just made off this list.
        let asked = [ids[2], ids[0]]
        let made = await model.duplicateElements(
            asked, on: pageID, offset: CGSize(width: 24, height: 24)
        )

        #expect(made.count == 2)
        #expect(Set(made).isDisjoint(with: Set(ids)))
        let elements = model.page(pageID)?.elements ?? []
        #expect(elements.count == 5)
        for (new, source) in zip(made, asked) {
            let copy = try #require(elements.first { $0.id == new })
            let original = try #require(elements.first { $0.id == source })
            #expect(copy.x == original.x + 24 ? true : false)
            #expect(copy.y == original.y + 24 ? true : false)
            #expect(copy.width == original.width ? true : false)
        }
    }

    @Test("Duplicating leaves the originals exactly where they were")
    func duplicateDoesNotDisturbTheSource() async throws {
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        let ids = await seedImages(model, on: pageID, count: 2)
        let before = (model.page(pageID)?.elements ?? []).map { CGPoint(x: $0.x, y: $0.y) }

        await model.duplicateElements(ids, on: pageID, offset: CGSize(width: 24, height: 24))

        let after = (model.page(pageID)?.elements ?? []).prefix(2).map { CGPoint(x: $0.x, y: $0.y) }
        #expect(Array(after) == before)
    }

    @Test("The one write actually reaches the disk, not just the published manifest")
    func theBatchIsPersisted() async throws {
        let (model, notebookID, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        let ids = await seedImages(model, on: pageID, count: 3)

        await model.deleteElements([ids[0]], on: pageID)
        await model.moveElements([ids[1]], on: pageID, by: CGSize(width: 10, height: 10))

        // A second model over the same package reads only what was written.
        let reopened = NotebookEditorModel(
            notebookID: notebookID, store: DocumentStore(rootURL: root)
        )
        await reopened.load()
        let elements = reopened.page(pageID)?.elements ?? []
        #expect(elements.count == 2)
        #expect(!elements.contains { $0.id == ids[0] })
        let moved = try #require(elements.first { $0.id == ids[1] })
        #expect(moved.x == 110 ? true : false)
    }
}

/// The bounding-box fast reject the lasso hit test now runs first.
@Suite("A lasso only pays for what it could have caught")
struct LassoBoundingBoxTests {
    @Test("No points, no box")
    func emptyHasNoBox() {
        #expect(LassoSelection.boundingBox(of: []) == nil)
    }

    @Test("The box is the exact extent of the points, including a single one")
    func boxIsExact() throws {
        let one = try #require(LassoSelection.boundingBox(of: [CGPoint(x: 7, y: 9)]))
        #expect(one == CGRect(x: 7, y: 9, width: 0, height: 0))

        let many = try #require(LassoSelection.boundingBox(of: [
            CGPoint(x: 10, y: 40), CGPoint(x: -5, y: 12), CGPoint(x: 30, y: 25),
        ]))
        #expect(many == CGRect(x: -5, y: 12, width: 35, height: 28))
    }

    /// The whole justification for the fast path: it must only ever reject
    /// things `catches` would have rejected anyway, or the lasso silently stops
    /// picking up ink it used to.
    @Test("Anything the box rejects, the real test would have rejected too")
    func rejectionIsExactNotHeuristic() throws {
        let loop = (0..<60).map { index -> CGPoint in
            let angle = Double(index) / 60 * 2 * .pi
            return CGPoint(x: 200 + cos(angle) * 80, y: 200 + sin(angle) * 80)
        }
        let box = try #require(LassoSelection.boundingBox(of: loop))

        // A grid of candidate strokes all over the page, far outside and well
        // inside. Every one the box rejects must also fail `catches`.
        var rejected = 0
        for x in stride(from: -100.0, through: 500.0, by: 20) {
            for y in stride(from: -100.0, through: 500.0, by: 20) {
                let stroke = [
                    CGPoint(x: x, y: y), CGPoint(x: x + 8, y: y + 4), CGPoint(x: x + 16, y: y + 9),
                ]
                let strokeBox = try #require(LassoSelection.boundingBox(of: stroke))
                guard !strokeBox.intersects(box) else { continue }
                rejected += 1
                #expect(!LassoSelection.catches(loop, stroke))
            }
        }
        // The test is only meaningful if the fast path actually fired.
        #expect(rejected > 100)
    }
}
