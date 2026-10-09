import Darwin
import Foundation
import NotesModels
import PencilKit
import Testing
import UIKit
@testable import NotesEditor
@testable import NotesServices

private func sessionFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

private func lectureHandout(pages: Int, lecture: Int) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
        for index in 0..<pages {
            context.beginPage()
            ("Lecture \(lecture) handout, page \(index + 1)" as NSString).draw(
                in: CGRect(x: 48, y: 48, width: 516, height: 100),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
            )
        }
    }
}

private func photo(_ seed: Int) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).pngData { context in
        UIColor(hue: CGFloat(seed % 12) / 12, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
    }
}

/// A page of writing that grows by one line of strokes per call, the way a
/// page does over a lecture.
private func writing(lines: Int, seed: Int) -> Data {
    let ink = PKInk(.pen, color: .black)
    var strokes: [PKStroke] = []
    for line in 0..<lines {
        for word in 0..<8 {
            let origin = CGPoint(x: 40 + CGFloat(word) * 80, y: 60 + CGFloat(line % 40) * 24)
            let points = (0..<14).map { step -> PKStrokePoint in
                let t = CGFloat(step)
                return PKStrokePoint(
                    location: CGPoint(x: origin.x + t * 4, y: origin.y + sin(t + CGFloat(seed)) * 5),
                    timeOffset: TimeInterval(step) * 0.01, size: CGSize(width: 2.2, height: 2.2),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: .now)))
        }
    }
    return PKDrawing(strokes: strokes).dataRepresentation()
}

/// §44: a student's whole university day, compressed. Six lectures across
/// three notebooks: writing page after page, photos, a handout PDF annotated,
/// tool switching, search, page navigation, deleting and restoring, closing
/// and reopening. Then the app is "relaunched" (a fresh store over the same
/// folder) and every page is checked against what was written.
///
/// The rules at the end: nothing lost, nothing corrupt, no memory that only
/// grows, and no lecture markedly slower than the first.
@MainActor
@Suite("A long session: a whole university day", .serialized)
struct LongSessionTests {

    @Test("Six lectures: no lost content, no corruption, no leak, no slowdown")
    func universityDay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-day-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let indexer = SearchIndexer(store: store)
        let courses = ["Biology", "Calculus", "History"]
        var notebooks: [UUID] = []
        for _ in courses {
            let id = UUID()
            _ = try await store.createDocument(id: id, style: PageStyle(template: .ruled, pageSize: .a4))
            notebooks.append(id)
        }

        /// What every page should hold when the day is over.
        var expectedInk: [UUID: Data] = [:]
        var expectedTypedText: [UUID: [String]] = [:]
        var lectureSeconds: [Double] = []
        var footprints: [Double] = []
        let clock = ContinuousClock()
        let tools: [ToolState.Tool] = [.pen, .eraser, .lasso, .text, .hand, .tape, .fill, .pen]

        for lecture in 0..<6 {
            let start = clock.now
            let id = notebooks[lecture % notebooks.count]
            let model = NotebookEditorModel(notebookID: id, store: store)
            await model.load()
            #expect(model.manifest != nil, "lecture \(lecture): the notebook opens")
            let toolState = ToolState()

            // Write for "45 minutes": three new pages, fifteen saves each, the
            // page growing with every save as the editor's autosave sees it.
            for _ in 0..<3 {
                let page = try #require(await model.appendInheritingLast())
                for minute in 1...15 {
                    let bytes = writing(lines: minute * 2, seed: lecture * 100 + minute)
                    let stamp = store.journal.stamp()
                    store.journal.stage(bytes, page: page, stamp: stamp)
                    try await store.savePageData(bytes, notebook: id, page: page, stamp: stamp)
                    expectedInk[page] = bytes
                    // Tools change mid-lecture.
                    toolState.select(tools[minute % tools.count])
                }
                // A photo of the board, and a typed note, on the same page.
                await model.drop(.image(photo(lecture), name: "board", fileExtension: "png"),
                                 on: page, at: CGPoint(x: 300, y: 600), fontName: "", colorHex: "#000000")
                let typed = "lecture\(lecture)keyword"
                await model.drop(.text(typed), on: page, at: CGPoint(x: 300, y: 900),
                                 fontName: "", colorHex: "#000000")
                expectedTypedText[page, default: []].append(typed)
            }

            // Annotate a handout every other lecture.
            if lecture.isMultiple(of: 2), let first = model.pages.first?.id {
                model.focusedPageID = first
                let outcome = await model.importPDF(lectureHandout(pages: 4, lecture: lecture))
                #expect(outcome?.skipped == 0)
                if let handoutPage = outcome?.firstPageID {
                    let bytes = writing(lines: 3, seed: lecture)
                    try await store.savePageData(bytes, notebook: id, page: handoutPage)
                    expectedInk[handoutPage] = bytes
                }
            }

            // Navigate: every page in turn, then a page moved.
            for page in model.pages { model.focusedPageID = page.id }
            if model.pages.count > 3 { await model.movePage(from: 1, to: model.pages.count - 1) }

            // Delete a page by mistake, and get it back.
            if let victim = model.pages.last?.id {
                await model.deletePage(victim)
                #expect(!model.pages.contains { $0.id == victim })
                await model.undoRecentDeletion()
                #expect(model.pages.contains { $0.id == victim }, "lecture \(lecture): the page comes back")
            }

            // Search for something typed this lecture.
            _ = await indexer.index(notebook: id)
            let targets = notebooks.enumerated().map { SearchTarget(id: $1, title: courses[$0]) }
            let hits = await indexer.search("lecture\(lecture)keyword", across: targets)
            #expect(hits.map(\.notebookID) == [id], "lecture \(lecture): search finds today's note")

            lectureSeconds.append(Double((clock.now - start).components.attoseconds) / 1e18
                                  + Double((clock.now - start).components.seconds))
            footprints.append(sessionFootprintMB())
        }

        // "Relaunch": a fresh store over the same folder, nothing in memory.
        let relaunched = DocumentStore(rootURL: root)
        var pagesChecked = 0
        for id in notebooks {
            let manifest = try await relaunched.manifest(for: id)
            for page in manifest.pages {
                if let expected = expectedInk[page.id] {
                    let stored = await relaunched.pageData(notebook: id, page: page.id)
                    #expect(stored == expected, "ink on a page written today is exactly what was written")
                    if let stored { #expect((try? PKDrawing(data: stored)) != nil, "and it decodes") }
                    pagesChecked += 1
                }
                for text in expectedTypedText[page.id] ?? [] {
                    #expect(page.elements.contains { $0.text == text }, "the typed note is still on its page")
                }
                for element in page.elements where element.kind == .image {
                    let file = try #require(element.payloadFilename)
                    #expect(FileManager.default.fileExists(
                        atPath: relaunched.mediaURL(notebook: id, filename: file).path
                    ), "every photo's file is still there")
                }
            }
            // Nothing was quarantined as unreadable.
            let package = relaunched.documentURL(for: id)
            let names = FileManager.default.enumerator(atPath: package.path)?.allObjects as? [String] ?? []
            #expect(!names.contains { $0.contains("unreadable") }, "no corrupt files")
        }
        #expect(pagesChecked == expectedInk.count, "every page written today was found")

        // No slowdown: the last lectures are not markedly slower than the first.
        let firstTwo = (lectureSeconds[0] + lectureSeconds[1]) / 2
        let lastTwo = (lectureSeconds[4] + lectureSeconds[5]) / 2
        // No leak: memory after the second lecture is the baseline (caches warm);
        // what remains after the sixth is bounded.
        let growth = footprints[5] - footprints[1]
        print("BENCH longSession.lecture.first2 = \(String(format: "%.2f", firstTwo)) s")
        print("BENCH longSession.lecture.last2 = \(String(format: "%.2f", lastTwo)) s")
        print("BENCH longSession.footprintGrowth.lectures2to6 = \(String(format: "%.1f", growth)) MB (from \(Int(footprints[1])) MB)")
        print("BENCH longSession.pagesWritten = \(expectedInk.count)")
        #expect(lastTwo < max(firstTwo * 2.5, firstTwo + 2), "no major performance degradation")
        #expect(growth < 80, "no memory that only grows")
    }
}

/// §79: 1,000 cycles of the app being resized, sent to the background and
/// brought back, with writing in between, and 0 data-loss events.
///
/// What a cycle does to the DATA is the part a resize or a background can
/// break, and that is what this drives: ink staged by the canvas, the
/// debounced save and the background flush racing each other with stamps
/// taken in either order, and every so often the process "killed" in the
/// background (a fresh store over the same folder). What a resize does to the
/// LAYOUT is checked from the same functions the editor lays pages out with:
/// any window width gives a real page, and the page's own space (where ink
/// lives) never changes with the window.
@MainActor
@Suite("Multitasking: 1,000 resize and background cycles", .serialized)
struct MultitaskingCycleTests {

    @Test("1,000 cycles, 0 data-loss events")
    func cycles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-cycles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var store = DocumentStore(rootURL: root)
        let id = UUID()
        let manifest = try await store.createDocument(id: id, style: PageStyle(template: .ruled, pageSize: .a4))
        let page = try #require(manifest.pages.first?.id)
        let logical = try #require(manifest.pages.first?.logicalSize)
        var rng = SystemRandomNumberGenerator()
        var lastWritten = Data()
        var losses = 0
        var kills = 0

        for cycle in 0..<1_000 {
            // Writing: two saves read off the canvas, stamped when read.
            let older = store.journal.stamp()
            let olderBytes = Data("cycle \(cycle) a".utf8)
            let newer = store.journal.stamp()
            let newerBytes = Data("cycle \(cycle) b".utf8)
            store.journal.stage(newerBytes, page: page, stamp: newer)

            // Background: the debounced save and the flush land in either order.
            if Bool.random(using: &rng) {
                try await store.savePageData(olderBytes, notebook: id, page: page, stamp: older)
                try await store.savePageData(newerBytes, notebook: id, page: page, stamp: newer)
            } else {
                try await store.savePageData(newerBytes, notebook: id, page: page, stamp: newer)
                try await store.savePageData(olderBytes, notebook: id, page: page, stamp: older)
            }
            lastWritten = newerBytes

            // Sometimes iOS ends the process while it's in the background.
            if Int.random(in: 0..<10, using: &rng) == 0 {
                store = DocumentStore(rootURL: root)
                kills += 1
            }

            // Foreground: what's on the page is the last thing written.
            if await store.pageData(notebook: id, page: page) != lastWritten { losses += 1 }

            // Resize: any window width, from Slide Over to an external display.
            let window = CGFloat.random(in: 320...2_560, using: &rng)
            let zoom = CGFloat.random(in: 0.5...4, using: &rng)
            let width = EditorScreen.pageWidth(in: window, zoom: zoom)
            let size = EditorScreen.pageSize(aspectRatio: logical.width / logical.height, width: width)
            #expect(width.isFinite && width > 0 && size.height.isFinite && size.height > 0,
                    "cycle \(cycle): a real page at \(window) points")
            #expect(abs(size.width / size.height - logical.width / logical.height) < 0.0001,
                    "cycle \(cycle): the page keeps its shape")
        }
        let reopened = try await DocumentStore(rootURL: root).manifest(for: id)
        #expect(reopened.pages.first?.logicalSize == logical, "the page's own space never moved")
        print("BENCH multitasking.cycles = 1000 (\(kills) background kills), data-loss events = \(losses)")
        #expect(losses == 0)
    }
}
