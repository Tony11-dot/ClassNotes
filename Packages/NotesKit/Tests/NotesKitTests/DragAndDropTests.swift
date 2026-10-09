import CoreGraphics
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import NotesEditor
import NotesModels
import NotesServices

private func dropPDF(pages: Int = 2) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
        for index in 0..<pages {
            context.beginPage()
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 20, y: 20 + index * 10, width: 60, height: 30))
        }
    }
}

private func dropImage(_ size: CGSize = CGSize(width: 400, height: 200)) -> Data {
    UIGraphicsImageRenderer(size: size).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

/// A provider offering `data` as `type`, the way another app's drag does.
private func provider(_ data: Data, as type: UTType, name: String? = nil) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
        completion(data, nil)
        return nil
    }
    provider.suggestedName = name
    return provider
}

// MARK: - What a drag becomes

@Suite("Drag and drop: what a drag becomes")
struct DropRoutingTests {

    @Test("A PDF from Files is pages, even though it is also a file URL")
    func pdfWinsOverFileURL() {
        #expect(DropRouting.kind(for: [UTType.fileURL.identifier, UTType.pdf.identifier]) == .pdf)
        #expect(DropRouting.identifier(for: .pdf, in: [UTType.fileURL.identifier, UTType.pdf.identifier])
            == UTType.pdf.identifier)
    }

    @Test("A photo is an image, in whatever format it comes")
    func images() {
        for type in [UTType.jpeg, .png, .heic, .tiff] {
            #expect(DropRouting.kind(for: [type.identifier]) == .image)
        }
    }

    @Test("A Safari link is a link before it is words")
    func linkBeforeText() {
        #expect(DropRouting.kind(for: [UTType.url.identifier, UTType.utf8PlainText.identifier]) == .link)
        #expect(DropRouting.kind(for: [UTType.utf8PlainText.identifier]) == .text)
    }

    @Test("Any other file is kept as a chip, never ignored")
    func otherFiles() {
        let docx = "org.openxmlformats.wordprocessingml.document"
        #expect(DropRouting.kind(for: [docx]) == .file)
        #expect(DropRouting.kind(for: [UTType.zip.identifier]) == .file)
        #expect(DropRouting.identifier(for: .file, in: [UTType.fileURL.identifier, docx]) == docx)
    }

    @Test("A drag offering nothing usable is refused")
    func nothing() {
        #expect(DropRouting.kind(for: []) == nil)
        #expect(DropRouting.kind(for: ["not a type at all"]) == nil)
    }

    @Test("The library takes notebooks-to-be only, and lets a notebook dragged to a shelf through")
    func library() {
        #expect(DropRouting.libraryKind(for: [UTType.pdf.identifier]) == .pdf)
        #expect(DropRouting.libraryKind(for: [UTType.png.identifier]) == .image)
        #expect(DropRouting.libraryKind(for: [UTType.zip.identifier]) == .file)
        // A notebook cover being dragged travels as its id in plain text.
        #expect(DropRouting.libraryKind(for: [UTType.utf8PlainText.identifier]) == nil)
        #expect(DropRouting.libraryKind(for: [UTType.url.identifier]) == nil)
    }

    @Test("A dropped file keeps its own extension")
    func extensions() {
        #expect(DropRouting.fileExtension(suggestedName: "Lecture 3.KEY", identifier: nil) == "key")
        #expect(DropRouting.fileExtension(suggestedName: "notes", identifier: UTType.pdf.identifier) == "pdf")
        #expect(DropRouting.fileExtension(suggestedName: nil, identifier: nil) == "bin")
    }

    @Test("A drop lands centred where it was let go, and never off the page")
    func placement() {
        let page = CGSize(width: 768, height: 1024)
        let middle = DropRouting.frame(size: CGSize(width: 100, height: 50), centredAt: CGPoint(x: 300, y: 400), on: page)
        #expect(middle == CGRect(x: 250, y: 375, width: 100, height: 50))
        let corner = DropRouting.frame(size: CGSize(width: 100, height: 50), centredAt: CGPoint(x: 760, y: 2), on: page)
        #expect(corner == CGRect(x: 668, y: 0, width: 100, height: 50))
        let huge = DropRouting.frame(size: CGSize(width: 1536, height: 512), centredAt: .zero, on: page)
        #expect(huge.width == 768 && huge.height == 256 && huge.minX == 0 && huge.minY == 0,
                "shrunk to the page, shape kept")
    }
}

// MARK: - Reading a drag

@MainActor
@Suite("Drag and drop: reading what was dragged")
struct DropLoaderTests {

    @Test("A PDF is read whole, with its name")
    func pdf() async throws {
        let data = dropPDF()
        let item = await DropLoader.load(provider(data, as: .pdf, name: "Handout.pdf"))
        #expect(item == .pdf(data, name: "Handout"))
    }

    @Test("A photo is read with its extension")
    func image() async throws {
        let data = dropImage()
        let item = await DropLoader.load(provider(data, as: .png, name: "board.png"))
        #expect(item == .image(data, name: "board", fileExtension: "png"))
    }

    @Test("A link, and words")
    func linkAndText() async throws {
        let link = NSItemProvider(object: URL(string: "https://example.com/syllabus")! as NSURL)
        #expect(await DropLoader.load(link) == .link(URL(string: "https://example.com/syllabus")!))
        let words = NSItemProvider(object: "Mitochondria make ATP" as NSString)
        #expect(await DropLoader.load(words) == .text("Mitochondria make ATP"))
        let blank = NSItemProvider(object: "   \n" as NSString)
        #expect(await DropLoader.load(blank) == nil, "nothing to place")
    }

    @Test("Any other file is read as a file")
    func file() async throws {
        let data = Data("PK\u{3}\u{4}zip".utf8)
        let item = await DropLoader.load(provider(data, as: .zip, name: "Lab data.zip"))
        #expect(item == .file(data, name: "Lab data.zip", fileExtension: "zip"))
    }
}

// MARK: - Placing it

@MainActor
@Suite("Drag and drop: what lands on the page")
struct DropPlacementTests {

    private func makeModel(pages: Int = 1) async throws -> (NotebookEditorModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-drop-\(UUID().uuidString)", isDirectory: true)
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        _ = try await store.createDocument(id: id, firstPageTemplate: .blank)
        let model = NotebookEditorModel(notebookID: id, store: store)
        await model.load()
        for _ in 1..<pages { _ = await model.insertPage(at: model.pages.count, inheriting: nil) }
        return (model, root)
    }

    @Test("A photo lands on the page it was dropped on, centred where it was let go")
    func photoWhereDropped() async throws {
        let (model, root) = try await makeModel(pages: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(model.pages.first?.id), second = try #require(model.pages.last?.id)
        model.focusedPageID = first

        let outcome = await model.drop(
            .image(dropImage(), name: "board", fileExtension: "png"),
            on: second, at: CGPoint(x: 300, y: 500), fontName: "", colorHex: "#000000"
        )
        #expect(outcome != nil)
        #expect(model.page(first)?.elements.isEmpty == true, "not the focused page")
        let image = try #require(model.page(second)?.elements.first)
        #expect(image.kind == .image)
        #expect(abs(image.x + image.width / 2 - 300) < 0.5 && abs(image.y + image.height / 2 - 500) < 0.5)
        #expect(model.focusedPageID == second)
        let file = try #require(image.payloadFilename)
        #expect(FileManager.default.fileExists(atPath: model.mediaURL(filename: file).path))
    }

    @Test("Words, a link and a file each become their element, kept on the page")
    func otherKinds() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(model.pages.first)
        let edge = CGPoint(x: page.logicalSize.width, y: page.logicalSize.height)

        await model.drop(.text("  Krebs cycle  "), on: page.id, at: edge, fontName: "Avenir", colorHex: "#112233")
        await model.drop(.link(URL(string: "https://example.com")!), on: page.id, at: edge, fontName: "", colorHex: "")
        await model.drop(.file(Data("x".utf8), name: "Lab.zip", fileExtension: "zip"),
                         on: page.id, at: edge, fontName: "", colorHex: "")

        let elements = try #require(model.page(page.id)?.elements)
        #expect(elements.map(\.kind) == [.text, .link, .file])
        #expect(elements[0].text == "Krebs cycle" && elements[0].fontName == "Avenir")
        #expect(elements[1].urlString == "https://example.com")
        #expect(elements[2].displayName == "Lab.zip")
        for element in elements {
            #expect(element.x + element.width <= page.logicalSize.width + 0.001)
            #expect(element.y + element.height <= page.logicalSize.height + 0.001)
        }
    }

    @Test("A PDF dropped on a page becomes pages straight after THAT page")
    func pdfAfterTarget() async throws {
        let (model, root) = try await makeModel(pages: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = model.pages.map(\.id)
        model.focusedPageID = pages[2]

        let outcome = await model.drop(.pdf(dropPDF(pages: 2), name: "Handout"), on: pages[0],
                                       at: .zero, fontName: "", colorHex: "")
        #expect(outcome?.skipped == 0)
        let after = model.pages
        #expect(after.count == 5)
        #expect(after[0].id == pages[0] && after[3].id == pages[1] && after[4].id == pages[2],
                "the original pages keep their order around the import")
        #expect(after[1].backgroundPDF != nil && after[2].backgroundPDF != nil)
    }

    @Test("A drop that can't be read changes nothing, and says so plainly")
    func unreadable() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(model.pages.first?.id)
        let outcome = await model.drop(.pdf(Data("not a pdf".utf8), name: "x"), on: page,
                                       at: .zero, fontName: "", colorHex: "")
        #expect(outcome == nil)
        #expect(model.pages.count == 1 && model.page(page)?.elements.isEmpty == true)
        #expect(EditorScreen.dropNotice(unreadable: 0, of: 3) == nil)
        #expect(EditorScreen.dropNotice(unreadable: 2, of: 2)?.contains("Nothing on this page was changed") == true)
        #expect(EditorScreen.dropNotice(unreadable: 1, of: 3) == "1 of the 3 things dropped couldn't be read and were left out.")
    }

    @Test("Repeated drops all land: 200 in a row, none lost")
    func repeated() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(model.pages.first?.id)
        let image = dropImage(CGSize(width: 40, height: 40))
        for index in 0..<200 {
            let item: DroppedItem = index.isMultiple(of: 2)
                ? .image(image, name: "i", fileExtension: "png")
                : .text("note \(index)")
            let outcome = await model.drop(item, on: page, at: CGPoint(x: index % 700, y: index * 5 % 1000),
                                           fontName: "", colorHex: "")
            #expect(outcome != nil)
        }
        #expect(model.page(page)?.elements.count == 200)
    }
}
