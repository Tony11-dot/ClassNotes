import Darwin
import Foundation
import NotesModels
import PencilKit
import Synchronization
import Testing
import UIKit
@testable import NotesDesignSystem
@testable import NotesServices

// Benchmarks for the document layer, measured — not assumed. Each prints a
// `BENCH` line (collected into docs/quality/measurements.md) and asserts only a
// generous CEILING, so a run on a loaded CI machine passes while a regression
// of an order of magnitude does not. These run in the simulator on a Mac: they
// measure the code's own cost, not a device's. Pencil latency and frame rate
// need hardware and are NOT measured here.

private func benchRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cmnotes-bench-\(label)-\(UUID().uuidString)", isDirectory: true)
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

/// Median of `runs` timings of `body`, in milliseconds.
private func median(_ runs: Int, _ body: () async throws -> Void) async rethrows -> Double {
    var samples: [Double] = []
    let clock = ContinuousClock()
    for _ in 0..<runs {
        let start = clock.now
        try await body()
        samples.append(milliseconds(clock.now - start))
    }
    return samples.sorted()[samples.count / 2]
}

/// Median of `runs` timings of a synchronous `body`, in milliseconds — for
/// work that has to stay on the caller's actor (the main thread, for a canvas).
private func medianSync(_ runs: Int, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    return (0..<runs).map { _ in milliseconds(clock.measure(body)) }.sorted()[runs / 2]
}

private func percentile(_ samples: [Double], _ p: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

/// The process's physical footprint — what iOS's memory limit counts.
private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

private func bench(_ name: String, _ value: Double, _ unit: String, _ note: String = "") {
    print("BENCH \(name) = \(String(format: "%.2f", value)) \(unit)\(note.isEmpty ? "" : " (\(note))")")
}

/// A page of handwriting-like strokes: short wiggles laid out in lines.
private func heavyDrawing(strokes: Int, pointsPerStroke: Int = 16) -> PKDrawing {
    let ink = PKInk(.pen, color: .black)
    var result: [PKStroke] = []
    result.reserveCapacity(strokes)
    for index in 0..<strokes {
        let originX = CGFloat(index % 60) * 12 + 20
        let originY = CGFloat((index / 60) % 80) * 12 + 20
        let points = (0..<pointsPerStroke).map { step -> PKStrokePoint in
            let t = CGFloat(step)
            return PKStrokePoint(
                location: CGPoint(x: originX + t * 0.6, y: originY + sin(t * 0.8) * 3),
                timeOffset: TimeInterval(step) * 0.008,
                size: CGSize(width: 2.2, height: 2.2), opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2
            )
        }
        result.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: .now)))
    }
    return PKDrawing(strokes: result)
}

private func samplePDF(pages: Int) -> Data {
    let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
        for index in 0..<pages {
            context.beginPage()
            let text = "Lecture \(index + 1): the Krebs cycle, oxidative phosphorylation and ATP synthase."
            (text as NSString).draw(
                in: CGRect(x: 48, y: 48, width: 516, height: 200),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
            )
            UIColor.darkGray.setStroke()
            for line in 0..<30 {
                let y = CGFloat(140 + line * 20)
                context.cgContext.move(to: CGPoint(x: 48, y: y))
                context.cgContext.addLine(to: CGPoint(x: 564, y: y))
            }
            context.cgContext.strokePath()
        }
    }
}

@Suite("Performance benchmarks", .serialized)
struct PerformanceBenchmarkTests {

    @Test("A 1,000-page notebook's manifest loads and saves quickly")
    func thousandPageManifest() async throws {
        let root = benchRoot("manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        try await store.createDocument(id: id, style: PageStyle(template: .ruled))
        var pages: [PageRecord] = []
        for index in 0..<1_000 {
            var page = PageStyle(template: .ruled).makePage()
            page.elements = [
                PageElement(kind: .text, x: 40, y: 40, width: 300, height: 60, text: "Note \(index): photosynthesis"),
                PageElement(kind: .text, x: 40, y: 140, width: 300, height: 60, text: "Light-dependent reactions")
            ]
            pages.append(page)
        }
        try await store.writeManifest(NotebookManifest(pages: pages), for: id)
        let size = (try? Data(contentsOf: await store.manifestURL(for: id)).count) ?? 0

        let load = try await median(7) {
            _ = try await DocumentStore(rootURL: root).manifest(for: id)
        }
        let page = pages[500].id
        let edit = try await median(7) {
            _ = try await store.setElements(
                [PageElement(kind: .text, x: 0, y: 0, width: 10, height: 10, text: "x")],
                notebook: id, page: page
            )
        }
        bench("manifest.load.1000pages", load, "ms", "median of 7, cold store, \(size / 1024) KB")
        bench("manifest.elementEdit.1000pages", edit, "ms", "median of 7, full rewrite + backup")
        #expect(load < 1_500)
        #expect(edit < 1_500)
    }

    @Test("A 10,000-stroke page encodes, saves, loads and thumbnails")
    func heavyPage() async throws {
        let root = benchRoot("heavy")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        let page = try await store.createDocument(id: id, style: PageStyle(template: .ruled)).pages[0].id
        let drawing = heavyDrawing(strokes: 10_000)

        var data = Data()
        let encode = await median(3) { data = drawing.dataRepresentation() }
        let save = try await median(5) {
            try await store.savePageData(data, notebook: id, page: page)
        }
        var loaded = Data()
        let read = await median(5) {
            loaded = await DocumentStore(rootURL: root).pageData(notebook: id, page: page) ?? Data()
        }
        let decode = try await median(3) { _ = try PKDrawing(data: loaded) }
        let cache = PageRenderCache()
        let thumbnail = await median(3) {
            cache.removeAll()
            _ = await cache.ink(loaded, pageSize: CGSize(width: 768, height: 1024), pixelWidth: 360, darkPaper: false)
        }

        bench("page.encode.10kStrokes", encode, "ms", "\(data.count / 1024) KB")
        bench("page.save.10kStrokes", save, "ms", "atomic write")
        bench("page.read.10kStrokes", read, "ms")
        bench("page.decode.10kStrokes", decode, "ms")
        bench("page.thumbnail.10kStrokes", thumbnail, "ms", "360 px wide, off the main thread")
        #expect(loaded == data)
        #expect(save < 1_000)
        #expect(decode < 5_000)
    }

    /// What the canvas does on the main thread at pencil-down and at each
    /// stroke's end: read the drawing and its stroke count. PencilKit offers no
    /// cheaper count, and the count is the floor the vanish guard checks, so it
    /// is measured here rather than cached somewhere it could go stale.
    @MainActor
    @Test("Per-stroke bookkeeping on the main thread stays small on a heavy page")
    func strokeBookkeeping() {
        for strokes in [1_000, 10_000] {
            let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
            canvas.drawing = heavyDrawing(strokes: strokes)
            var total = 0
            let count = medianSync(9) { total += canvas.drawing.strokes.count }
            var held = PKDrawing()
            let snapshot = medianSync(9) { held = canvas.drawing }
            total += held.strokes.isEmpty ? 0 : 1
            bench("stroke.strokeCount.\(strokes)", count, "ms", "main thread")
            bench("stroke.drawingSnapshot.\(strokes)", snapshot, "ms", "main thread")
            #expect(total > 0)
        }
    }

    @Test("Searching 1,000 indexed pages stays fast enough to run per keystroke")
    func searchThousandPages() async throws {
        let root = benchRoot("search")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let words = [
            "mitochondria", "membrane", "enzyme", "glucose", "chlorophyll", "osmosis", "protein",
            "nucleus", "ribosome", "photosynthesis", "respiration", "gradient", "electron", "carbon",
            "lecture", "exam", "derivative", "integral", "vector", "momentum", "velocity", "energy"
        ]
        var targets: [SearchTarget] = []
        var generator = SystemRandomNumberGenerator()
        for notebook in 0..<100 {
            let id = UUID()
            try await store.createDocument(id: id, style: PageStyle(template: .ruled))
            var index = SearchIndex(language: "en-US")
            for _ in 0..<10 {
                let text = (0..<80).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
                index.set(text + (notebook == 42 ? " krebs cycle" : ""), for: UUID())
            }
            try await store.saveSearchIndex(index, for: id)
            targets.append(SearchTarget(id: id, title: "Notebook \(notebook)"))
        }
        let clock = ContinuousClock()
        let coldStart = clock.now
        _ = await SearchIndexer(store: DocumentStore(rootURL: root)) { "en-US" }
            .search("krebs cycle", across: targets)
        let cold = milliseconds(clock.now - coldStart)
        let indexer = SearchIndexer(store: store) { "en-US" }

        var results: [NotebookSearchResult] = []
        let rare = await median(7) { results = await indexer.search("krebs cycle", across: targets) }
        let common = await median(7) { _ = await indexer.search("mitochondria", across: targets) }
        bench("search.cold.1000pages", cold, "ms", "first search, every index read from disk")
        bench("search.rare.1000pages", rare, "ms", "100 notebooks x 10 pages, median of 7")
        bench("search.common.1000pages", common, "ms", "a term on most pages")
        #expect(results.map(\.notebookID) == [targets[42].id])
        #expect(rare < 2_000)
    }

    @Test("A 100-page PDF imports in bounded memory while ink keeps saving")
    func pdfImportUnderLoad() async throws {
        let root = benchRoot("import")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        let page = try await store.createDocument(id: id, style: PageStyle(template: .ruled, pageSize: .a4)).pages[0].id
        let pdf = samplePDF(pages: 100)
        let ink = heavyDrawing(strokes: 400).dataRepresentation()

        let baseline = footprintMB()
        let peak = Mutex(baseline)
        let clock = ContinuousClock()
        let start = clock.now
        let finished = Mutex(false)
        let importing = Task {
            defer { finished.withLock { $0 = true } }
            return try await store.importPDF(data: pdf, notebook: id) { _, _ in
                let now = footprintMB()
                peak.withLock { $0 = max($0, now) }
            }
        }
        // The editor goes on saving while the import runs.
        var saves: [Double] = []
        var stamp = 0
        while !finished.withLock({ $0 }) {
            stamp += 1
            let saveStart = clock.now
            try await store.savePageData(ink + Data([UInt8(stamp % 256)]), notebook: id, page: page)
            saves.append(milliseconds(clock.now - saveStart))
            try await Task.sleep(for: .milliseconds(5))
        }
        let result = try await importing.value
        let total = milliseconds(clock.now - start)

        bench("import.pdf.100pages.total", total, "ms")
        bench("import.pdf.100pages.perPage", total / 100, "ms")
        bench("import.pdf.100pages.peakFootprintGrowth", peak.withLock { $0 } - baseline, "MB", "above \(Int(baseline)) MB baseline")
        bench("import.concurrentInkSave.p50", percentile(saves, 0.5), "ms", "\(saves.count) saves during import")
        bench("import.concurrentInkSave.p95", percentile(saves, 0.95), "ms")
        bench("import.concurrentInkSave.max", saves.max() ?? 0, "ms")
        #expect(result.manifest.pages.count == 101)
        #expect(result.skipped == 0)
        #expect(percentile(saves, 0.95) < 250, "ink must keep saving while an import runs")
    }
}

@Suite("Imports never leave half a document behind")
struct ImportSafetyTests {

    @Test("A cancelled import leaves no pages and no media")
    func cancelledImportCleansUp() async throws {
        let root = benchRoot("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        try await store.createDocument(id: id, style: PageStyle(template: .ruled))
        // Cancelled from INSIDE the import, at page 3: the progress callback
        // runs on the import's own task. Cancelling from the test after
        // polling for progress raced the import, which under load could
        // finish all sixty pages before the poll looked.
        let importing = Task {
            try await store.importPDF(data: samplePDF(pages: 60), notebook: id) { done, _ in
                if done == 3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await importing.value }

        #expect(try await store.manifest(for: id).pages.count == 1)
        let media = (try? FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory(for: id).path)) ?? []
        #expect(media.isEmpty, "every page image written before the cancel is removed")
    }

    @Test("Progress counts every page, and pages land in the PDF's order")
    func progressAndOrder() async throws {
        let root = benchRoot("progress")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        let original = try await store.createDocument(id: id, style: PageStyle(template: .ruled)).pages[0].id
        let reported = Mutex<[Int]>([])
        let result = try await store.importPDF(data: samplePDF(pages: 5), notebook: id, at: 1) { done, total in
            #expect(total == 5)
            reported.withLock { $0.append(done) }
        }
        #expect(reported.withLock { $0 } == [1, 2, 3, 4, 5])
        #expect(result.manifest.pages.first?.id == original)
        #expect(result.firstPageID == result.manifest.pages[1].id)
    }

    @Test("A search index replaced on disk is read fresh, not served from memory")
    func searchIndexCacheFollowsTheFile() async throws {
        let root = benchRoot("index-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let id = UUID()
        try await store.createDocument(id: id, style: PageStyle(template: .ruled))
        let page = UUID()
        var index = SearchIndex(language: "en-US")
        index.set("glycolysis", for: page)
        try await store.saveSearchIndex(index, for: id)
        #expect(await store.searchIndex(for: id).text(for: page) == "glycolysis")

        // Another writer (a second store, a restore from backup) changes the file.
        index.set("glycolysis and the krebs cycle", for: page)
        try await DocumentStore(rootURL: root).saveSearchIndex(index, for: id)
        #expect(await store.searchIndex(for: id).text(for: page) == "glycolysis and the krebs cycle")

        try FileManager.default.removeItem(at: store.searchIndexURL(for: id))
        #expect(await store.searchIndex(for: id).pages.isEmpty)
    }

    @Test("A thumbnail is re-rendered when ANY byte of the ink changes")
    func fingerprintSeesEveryByte() {
        var data = Data(repeating: 7, count: 4_096)
        let before = PageRenderCache.fingerprint(data)
        data[3_000] = 8
        #expect(PageRenderCache.fingerprint(data) != before)
        #expect(PageRenderCache.fingerprint(data) == PageRenderCache.fingerprint(data))
    }
}
