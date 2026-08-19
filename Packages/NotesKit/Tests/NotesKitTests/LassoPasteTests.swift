import CoreGraphics
import Foundation
import NotesEditor
import NotesModels
import NotesServices
import Testing

/// The model-layer half of "lasso, Copy, Paste": once a copied region's
/// picture, source page and frame are in hand, does pasting actually put an
/// element back in the right place?
///
/// The regression this guards: `EditorScreenTools.pasteSnip()` used to read
/// the paste destination off the live `lassoSelection`, which the user is free
/// to dismiss (its own "Done" button, or a tap anywhere else on the page)
/// before ever pressing the still-visible Paste chip. Once that selection was
/// gone, Paste silently fell back to `insertImage(_:fileExtension:)`, which
/// CENTERS on whichever page is currently focused — invisible on a page taller
/// than the viewport, and wrong entirely if focus had moved to a different
/// page since the copy. The fix carries the page id and frame captured AT COPY
/// TIME (`CopiedSnip`) instead of re-reading them from the dismissible
/// selection. This suite pins the model-layer half of that: the exact-frame
/// insert this fix depends on, and that it targets the ORIGINAL page even when
/// a different page is now focused.
@MainActor
@Suite("Lasso paste lands where it was copied from")
struct LassoPasteTests {
    private func makeModel() async throws -> (NotebookEditorModel, UUID, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-paste-\(UUID().uuidString)", isDirectory: true)
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .blank)
        let model = NotebookEditorModel(notebookID: id, store: store)
        await model.load()
        return (model, id, root)
    }

    @Test("An exact-frame paste lands at that frame, not the page's center")
    func pastesAtTheCopiedFrame() async throws {
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        let frame = CGRect(x: 40, y: 260, width: 180, height: 120)

        await model.insertImage(Data("snip".utf8), fileExtension: "png", frame: frame, on: pageID)

        let elements = model.page(pageID)?.elements ?? []
        #expect(elements.count == 1)
        let placed = try #require(elements.first)
        #expect(placed.kind == .image)
        // `#expect(a == b)`'s specialized binary-operation macro path reports
        // a false failure here — confirmed by comparing against a plain `==`
        // on the identical operands, bit pattern and all, within the same
        // run — specifically for a `PageElement.x` (Double) vs `CGRect.minX`
        // (CGFloat) comparison on this toolchain. The ternary keeps the
        // argument from being pattern-matched as a bare binary op, which
        // routes it through the plain boolean-expectation path instead.
        #expect(placed.x == frame.minX ? true : false)
        #expect(placed.y == frame.minY ? true : false)
        #expect(placed.width == frame.width ? true : false)
        #expect(placed.height == frame.height ? true : false)
        // Not the page's logical center, which is what the old frame-less
        // fallback would have produced instead.
        let pageSize = model.page(pageID)?.logicalSize ?? .zero
        #expect(placed.x != (pageSize.width - frame.width) / 2)
    }

    @Test("Pasting targets the page the copy came from, even if a different page is now focused")
    func pastesOnItsOwnPageRegardlessOfCurrentFocus() async throws {
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await model.insertPage(at: 1, inheriting: nil)
        let pages = model.pages
        #expect(pages.count == 2)
        let copiedFromPage = pages[0].id
        let laterFocusedPage = pages[1].id

        // Simulate focus having moved to the second page between Copy and
        // Paste — the exact scenario the fix has to survive.
        model.focusedPageID = laterFocusedPage

        let frame = CGRect(x: 20, y: 30, width: 100, height: 80)
        await model.insertImage(Data("snip".utf8), fileExtension: "png", frame: frame, on: copiedFromPage)

        #expect((model.page(copiedFromPage)?.elements ?? []).count == 1)
        #expect((model.page(laterFocusedPage)?.elements ?? []).isEmpty)
    }

    @Test("Two pastes of the same copied snip both land, independently")
    func pastingTwiceInsertsTwoElements() async throws {
        // The Paste chip is never cleared after a successful paste — pressing
        // it again pastes the same region a second time. Both inserts must
        // succeed and persist, not just the first.
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        let frame = CGRect(x: 10, y: 10, width: 60, height: 60)

        await model.insertImage(Data("snip".utf8), fileExtension: "png", frame: frame, on: pageID)
        await model.insertImage(Data("snip".utf8), fileExtension: "png", frame: frame, on: pageID)

        #expect((model.page(pageID)?.elements ?? []).count == 2)
    }

    @Test("A frame-less paste centers on the target page, for a snip with no known source")
    func framelessPasteCenters() async throws {
        // The fallback for a picture copied from outside the app (no source
        // page/frame at all) — still expected to land somewhere visible.
        let (model, _, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pageID = try #require(model.pages.first?.id)
        let pageSize = model.page(pageID)?.logicalSize ?? .zero

        await model.insertImage(Data("snip".utf8), fileExtension: "png")

        let placed = try #require(model.page(pageID)?.elements.first)
        #expect(abs((placed.x + placed.width / 2) - pageSize.width / 2) < 0.01)
        #expect(abs((placed.y + placed.height / 2) - pageSize.height / 2) < 0.01)
    }
}
