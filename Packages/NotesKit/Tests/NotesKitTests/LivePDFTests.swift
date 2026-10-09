import ClassMateTheme
import Foundation
import PDFKit
import Testing
import UIKit
@testable import NotesDesignSystem
@testable import NotesModels
@testable import NotesServices

/// A three-page handout with real text, and a black block in each page's top
/// left corner (where the page is, as it is shown).
private func handout(pages: Int = 3) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
        for number in 1...pages {
            context.beginPage()
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 150, height: 150))
            ("Photosynthesis handout page \(number)" as NSString).draw(
                at: CGPoint(x: 60, y: 300),
                withAttributes: [.font: UIFont.systemFont(ofSize: 28)]
            )
        }
    }
}

private func notebook() async throws -> (DocumentStore, UUID, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmnotes-livepdf-\(UUID().uuidString)", isDirectory: true)
    let store = DocumentStore(rootURL: root)
    let id = UUID()
    try await store.createDocument(id: id, style: PageStyle(template: .blank))
    return (store, id, root)
}

private func mediaFiles(_ store: DocumentStore, _ id: UUID) -> [String] {
    let dir = store.mediaURL(notebook: id, filename: "x").deletingLastPathComponent()
    return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
}

/// How dark the pixel at `point` (in points) of `image` is, 0 white … 1 black.
private func darkness(of image: UIImage, at point: CGPoint) -> CGFloat {
    let cg = image.cgImage!
    let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
    return 1 - CGFloat(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
}

@Suite("PDF pages drawn live from the PDF (manifest v9)")
struct LivePDFTests {

    @Test("A v8 page reads with no PDF; a damaged reference costs the reference, not the page")
    func compatibility() throws {
        let v8 = #"{"id":"\#(UUID().uuidString)","template":"blank","createdAt":0,"backgroundPayloadFilename":"a.png"}"#
        let page = try JSONDecoder().decode(PageRecord.self, from: Data(v8.utf8))
        #expect(page.backgroundPDF == nil && page.backgroundPayloadFilename == "a.png")

        let damaged = #"{"id":"\#(UUID().uuidString)","template":"blank","createdAt":0,"backgroundPDF":"nonsense"}"#
        let survived = try JSONDecoder().decode(PageRecord.self, from: Data(damaged.utf8))
        #expect(survived.backgroundPDF == nil)

        var record = PageStyle().makePage(backgroundPayloadFilename: "p.png", backgroundPDF: PDFBackground(filename: "d.pdf", pageIndex: 2))
        record.isBookmarked = true
        let round = try JSONDecoder().decode(PageRecord.self, from: JSONEncoder().encode(record))
        #expect(round == record)
    }

    @Test("Importing a PDF keeps it once, and every page names its own page of it, with its PNG beside it")
    func importKeepsThePDF() async throws {
        let (store, id, root) = try await notebook()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.importPDF(data: handout(), notebook: id)
        let imported = try await store.manifest(for: id).pages.filter { $0.backgroundPDF != nil }
        #expect(imported.map { $0.backgroundPDF!.pageIndex } == [0, 1, 2])
        #expect(Set(imported.map { $0.backgroundPDF!.filename }).count == 1)
        #expect(imported.allSatisfy { $0.backgroundPayloadFilename != nil }, "older builds still see the page")
        let files = mediaFiles(store, id)
        #expect(files.filter { $0.hasSuffix(".pdf") }.count == 1)
        #expect(files.filter { $0.hasSuffix(".png") }.count == 3)
    }

    @Test("Search reads a PDF page's own text: exact words, no recognition")
    func searchUsesTheTextLayer() async throws {
        let (store, id, root) = try await notebook()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.importPDF(data: handout(), notebook: id)
        let pages = try await store.manifest(for: id).pages.filter { $0.backgroundPDF != nil }
        let index = await SearchIndexer(store: store) { "en-US" }.index(notebook: id)
        #expect(index.text(for: pages[1].id)?.contains("Photosynthesis handout page 2") == true)
    }

    @Test("The shared PDF stays while any page uses it, and goes with the last one")
    func purgeKeepsSharedPDF() async throws {
        let (store, id, root) = try await notebook()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.importPDF(data: handout(), notebook: id)
        let pages = try await store.manifest(for: id).pages.filter { $0.backgroundPDF != nil }

        _ = try await store.deletePage(notebook: id, page: pages[0].id)
        try await store.purgePages([pages[0].id], notebook: id)
        #expect(mediaFiles(store, id).contains { $0.hasSuffix(".pdf") })

        for page in pages.dropFirst() {
            _ = try await store.deletePage(notebook: id, page: page.id)
        }
        try await store.purgePages(pages.dropFirst().map(\.id), notebook: id)
        #expect(!mediaFiles(store, id).contains { $0.hasSuffix(".pdf") })
    }

    @Test("Sending a PDF page to another notebook takes the PDF with it")
    func transferCarriesThePDF() async throws {
        let (store, id, root) = try await notebook()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = UUID()
        try await store.createDocument(id: other, style: PageStyle(template: .blank))
        _ = try await store.importPDF(data: handout(), notebook: id)
        let page = try #require(try await store.manifest(for: id).pages.first { $0.backgroundPDF != nil })
        _ = try await store.transferPages([page.id], from: id, to: other, removingFromSource: false)
        let moved = try #require(try await store.manifest(for: other).pages.first { $0.backgroundPDF != nil })
        #expect(FileManager.default.fileExists(atPath: store.mediaURL(notebook: other, filename: moved.backgroundPDF!.filename).path))
    }

    @Test("A page is placed aspect-fit and centred, as the import always placed it")
    func placement() {
        let place = PDFPageFit.placement(
            mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0,
            in: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        #expect(abs(place.height - 1000) < 0.001)
        #expect(abs(place.midX - 500) < 0.001)
        let turned = PDFPageFit.shownSize(mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 90)
        #expect(turned == CGSize(width: 792, height: 612))
    }

    @Test("A rotated page is drawn the way it is shown, matching PDFKit", arguments: [0, 90, 180, 270])
    func rotation(degrees: Int) throws {
        let document = try #require(PDFDocument(data: handout(pages: 1)))
        document.page(at: 0)?.rotation = degrees
        let data = try #require(document.dataRepresentation())
        let cgPage = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.page(at: 1))
        let size = CGSize(width: 400, height: 400)
        let ours = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            PDFPageDrawing.draw(cgPage, in: CGRect(origin: .zero, size: size), context: context.cgContext)
        }
        let theirs = try #require(PDFDocument(data: data)?.page(at: 0)).thumbnail(of: size, for: .mediaBox)
        // The black block sits in one corner of the page as shown; both
        // renderings must agree which.
        let place = PDFPageFit.placement(
            mediaBox: cgPage.getBoxRect(.mediaBox), rotation: Int(cgPage.rotationAngle),
            in: CGRect(origin: .zero, size: size)
        )
        let theirPlace = CGRect(
            x: (size.width - theirs.size.width) / 2, y: (size.height - theirs.size.height) / 2,
            width: theirs.size.width, height: theirs.size.height
        )
        for corner in [(0.08, 0.08), (0.92, 0.08), (0.08, 0.92), (0.92, 0.92)] {
            let ourPoint = CGPoint(x: place.minX + place.width * corner.0, y: place.minY + place.height * corner.1)
            let theirPoint = CGPoint(x: theirs.size.width * corner.0, y: theirs.size.height * corner.1)
            _ = theirPlace
            let ourDark = darkness(of: ours, at: ourPoint) > 0.5
            let theirDark = darkness(of: theirs, at: theirPoint) > 0.5
            #expect(ourDark == theirDark, "corner \(corner) at \(degrees)°")
        }
    }

    @Test("The tile drawer draws the page where it belongs")
    func tileDrawer() throws {
        let data = handout(pages: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let drawer = PDFTileDrawer()
        _ = drawer.set(PDFBackgroundSource(url: url, pageIndex: 0))
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let image = UIGraphicsImageRenderer(size: layer.bounds.size).image { context in
            drawer.draw(layer, in: context.cgContext)
        }
        #expect(darkness(of: image, at: CGPoint(x: 40, y: 40)) > 0.8, "the block is top left")
        #expect(darkness(of: image, at: CGPoint(x: 560, y: 740)) < 0.1, "and nothing bottom right")
    }

    @Test("Export draws a PDF page as vector: its text is still text in the exported file")
    @MainActor
    func exportKeepsVector() async throws {
        let (store, id, root) = try await notebook()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.importPDF(data: handout(), notebook: id)
        let book = Notebook(id: id, title: "Handout", coverColorHex: ThemePreset.light.accent.hexString, showsCover: false)
        let exporter = NotebookExporter(store: store, theme: ThemePreset.light.spec, paperTone: .neutral)
        let pdf = try #require(await exporter.pdf(notebook: book, scale: 1))
        let exported = try #require(PDFDocument(data: pdf))
        let texts = (0..<exported.pageCount).compactMap { exported.page(at: $0)?.string }
        #expect(texts.contains { $0.contains("Photosynthesis handout page 3") })
    }
}
