import Foundation
import NotesModels
import SwiftData
import Testing
@testable import NotesServices

@MainActor
@Suite("Models")
struct ModelTests {
    @Test("Notebook defaults and template raw-value safety")
    func notebookDefaults() {
        let notebook = Notebook(title: "Physics", coverColorHex: "#256489")
        #expect(notebook.defaultTemplate == .ruled)
        #expect(notebook.updatedAt == notebook.createdAt)

        notebook.defaultTemplateRaw = "not-a-template"
        #expect(notebook.defaultTemplate == .ruled)

        notebook.defaultTemplate = .dotGrid
        #expect(notebook.defaultTemplateRaw == "dotGrid")
    }

    @Test("Notebook persists and fetches through the shared schema")
    func notebookPersistence() throws {
        // Hold the container — contexts don't retain it.
        let container = ModelContainerFactory.make(inMemory: true)
        let context = container.mainContext
        context.insert(Notebook(title: "Chemistry", coverColorHex: "#416835"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Notebook>())
        #expect(fetched.count == 1)
        #expect(fetched[0].title == "Chemistry")
    }

    @Test("Manifest JSON round-trips with ISO dates")
    func manifestCodable() throws {
        let manifest = NotebookManifest(pages: [
            PageRecord(template: .ruled),
            PageRecord(template: .dotGrid)
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(NotebookManifest.self, from: data)
        #expect(decoded.pages.map(\.id) == manifest.pages.map(\.id))
        #expect(decoded.pages.map(\.template) == [.ruled, .dotGrid])
    }

    @Test("Custom theme spec IDs round-trip through the record UUID")
    func specIDMapping() throws {
        let uuid = UUID()
        let specID = ThemeService.specID(for: uuid)
        #expect(specID.hasPrefix("custom-"))
        #expect(ThemeService.uuid(fromSpecID: specID) == uuid)
        #expect(ThemeService.uuid(fromSpecID: "matcha") == nil)
    }
}
