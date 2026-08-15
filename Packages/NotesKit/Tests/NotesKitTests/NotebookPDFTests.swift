import CoreGraphics
import Foundation
import PDFKit
import Testing
import UIKit
@testable import NotesDesignSystem

/// Exporting a notebook as a PDF — the thing that makes notes handable to a
/// teacher, a printer or a study group.
@Suite("PDF export")
struct NotebookPDFTests {
    private func page(width: CGFloat, height: CGFloat, color: UIColor = .white) -> NotebookPDF.RenderedPage {
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return NotebookPDF.RenderedPage(size: size, image: image)
    }

    @Test("Every page in comes out as a page of the PDF")
    func everyPageIsExported() throws {
        let data = NotebookPDF.data(
            from: [page(width: 400, height: 600), page(width: 400, height: 600)],
            title: "Physics"
        )
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 2)
    }

    @Test("Each page keeps its OWN size")
    func mixedPageSizesSurvive() throws {
        // A notebook with an A4 scan dropped into the middle of it must not have
        // that page letterboxed or cropped to whatever size page one happened to
        // be — a PDF that crops the page is worse than no PDF.
        let data = NotebookPDF.data(
            from: [page(width: 400, height: 600), page(width: 595, height: 842)],
            title: "Mixed"
        )
        let document = try #require(PDFDocument(data: data))
        let first = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        let second = try #require(document.page(at: 1)).bounds(for: .mediaBox)

        #expect(Int(first.width) == 400)
        #expect(Int(first.height) == 600)
        #expect(Int(second.width) == 595)
        #expect(Int(second.height) == 842)
    }

    @Test("The notebook's name travels with the file")
    func titleIsCarried() throws {
        let data = NotebookPDF.data(from: [page(width: 300, height: 400)], title: "Chemistry")
        let document = try #require(PDFDocument(data: data))
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        #expect(title == "Chemistry")
    }

    @Test("Nothing to export still produces a file a reader will open")
    func emptyExportIsStillValid() throws {
        // `data(from:)` is handed whatever survived rendering, which can be
        // nothing. UIKit's PDF renderer always emits at least one page, so what
        // comes back is a single blank sheet — not bytes that no reader accepts.
        // `NotebookExporter` refuses before it gets here, so nobody is actually
        // handed the blank sheet; this pins the floor.
        let data = NotebookPDF.data(from: [], title: "Empty")
        #expect(!data.isEmpty)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
    }

    @Test("The filename is the notebook's own name, minus what a file system rejects")
    func filenameIsSafe() {
        #expect(NotebookPDF.filename(for: "Physics") == "Physics.pdf")
        #expect(NotebookPDF.filename(for: "Term 1/2 Revision") == "Term 1 2 Revision.pdf")
        // A title that is nothing but punctuation still has to produce a file.
        #expect(NotebookPDF.filename(for: "///") == "Notebook.pdf")
        #expect(NotebookPDF.filename(for: "   ") == "Notebook.pdf")
    }
}
