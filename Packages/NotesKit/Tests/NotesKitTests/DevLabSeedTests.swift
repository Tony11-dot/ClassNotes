import Foundation
import NotesModels
import PencilKit
import Testing
@testable import NotesServices

/// Writes a large library to a folder, for measuring the app on a real iPad
/// (docs/quality/measurements.md, "On device"): 120 notebooks of 8 handwritten
/// pages and one of 300, each package describing itself so the app adopts
/// them at launch. Off by default; run with
/// `CLASSNOTES_DEVLAB_SEED=/path/to/folder`.
@Suite(
    "Device lab library",
    .enabled(if: ProcessInfo.processInfo.environment["CLASSNOTES_DEVLAB_SEED"] != nil)
)
struct DevLabSeedTests {

    private func page(strokes: Int, seed: Int) -> Data {
        let ink = PKInk(.pen, color: .black)
        let result = (0..<strokes).map { index -> PKStroke in
            let originX = CGFloat(index % 50) * 14 + 30
            let originY = CGFloat((index / 50) % 70) * 14 + 40
            let points = (0..<16).map { step -> PKStrokePoint in
                let t = CGFloat(step)
                return PKStrokePoint(
                    location: CGPoint(x: originX + t * 0.6, y: originY + sin(t * 0.8 + CGFloat(seed)) * 3),
                    timeOffset: TimeInterval(step) * 0.008, size: CGSize(width: 2.2, height: 2.2),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: .now))
        }
        return PKDrawing(strokes: result).dataRepresentation()
    }

    private func notebook(
        _ store: DocumentStore, title: String, pages: Int, strokes: Int, updated: Date
    ) async throws {
        let id = UUID()
        let manifest = try await store.createDocument(id: id, style: PageStyle(template: .ruled), pageCount: pages)
        for (index, record) in manifest.pages.enumerated() {
            try await store.savePageData(page(strokes: strokes, seed: index), notebook: id, page: record.id)
        }
        try await store.writeInfo(NotebookInfo(
            id: id, title: title, kind: NotebookKind.notebook.rawValue, coverColorHex: "#3F6FD8",
            coverDesign: CoverDesign.default.rawValue, showsCover: false,
            defaultTemplate: PageTemplate.ruled.rawValue, pageSize: PageSize.classic.rawValue,
            orientation: PageOrientation.portrait.rawValue, paperColorHex: nil, lineColorHex: nil,
            lineSpacingSteps: PageLineSpacing.default, shelfID: nil, shelfName: nil, shelfColorHex: nil,
            shelfSymbol: nil, isFavorite: false, isViewOnly: false, createdAt: updated, updatedAt: updated,
            deletedAt: nil
        ))
    }

    @Test("Write the device lab library")
    func seed() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["CLASSNOTES_DEVLAB_SEED"])
        let root = URL(fileURLWithPath: folder).appendingPathComponent("Notebooks", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let store = DocumentStore(rootURL: root)
        try await notebook(store, title: "Big notebook (300 pages)", pages: 300, strokes: 400, updated: .now)
        for index in 0..<120 {
            try await notebook(
                store, title: "Notebook \(index + 1)", pages: 8, strokes: 300,
                updated: .now.addingTimeInterval(-Double(index) * 3600)
            )
        }
        print("DEVLAB seeded \(root.path)")
    }
}
