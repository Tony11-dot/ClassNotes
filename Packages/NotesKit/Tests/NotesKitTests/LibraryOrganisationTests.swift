import ClassMateTheme
import Foundation
import NotesModels
import SwiftData
import Testing
@testable import NotesServices

// MARK: - Shelves inside shelves

@Suite("Shelves inside shelves")
struct ShelfTreeTests {
    let school = UUID(), biology = UUID(), cells = UUID(), journal = UUID()

    var tree: ShelfTree {
        ShelfTree([(school, nil), (biology, school), (cells, biology), (journal, nil)])
    }

    @Test("Top level, children and the way back up")
    func structure() {
        let order = [school, biology, cells, journal]
        #expect(tree.children(of: nil, in: order) == [school, journal])
        #expect(tree.children(of: school, in: order) == [biology])
        #expect(tree.ancestors(of: cells) == [biology, school])
        #expect(tree.parent(of: school) == nil)
    }

    @Test("A shelf holds everything inside it, at any depth")
    func subtree() {
        #expect(tree.subtree(of: school) == [school, biology, cells])
        #expect(tree.subtree(of: journal) == [journal])
    }

    @Test("A shelf can't go inside itself or anything inside it")
    func noCycles() {
        #expect(!tree.canMove(school, under: school))
        #expect(!tree.canMove(school, under: cells))
        #expect(tree.canMove(cells, under: journal))
        #expect(tree.canMove(cells, under: nil))
    }

    @Test("A damaged store whose parents loop shows those shelves at the top, and doesn't hang")
    func loopsDontHide() {
        let a = UUID(), b = UUID()
        let looped = ShelfTree([(a, b), (b, a)])
        #expect(looped.parent(of: a) == nil && looped.parent(of: b) == nil)
        #expect(Set(looped.children(of: nil, in: [a, b])) == [a, b])
    }

    @Test("A shelf whose parent is gone counts as top level")
    func orphanIsTopLevel() {
        let orphan = UUID()
        let tree = ShelfTree([(orphan, UUID())])
        #expect(tree.children(of: nil, in: [orphan]) == [orphan])
    }
}

@Suite("Tags")
struct NotebookTagRulesTests {
    @Test("Tags are tidied as typed", arguments: [
        ("  exam ", "exam"), ("#revision", "revision"), ("cell   biology", "cell biology"), ("   ", nil), ("##", nil)
    ])
    func normalised(raw: String, expected: String?) {
        #expect(NotebookTags.normalised(raw) == expected)
    }

    @Test("The same word in a different case is the same tag")
    func caseInsensitive() {
        let tags = NotebookTags.adding("Exam", to: ["exam"])
        #expect(tags == ["exam"])
        #expect(NotebookTags.removing("EXAM", from: tags).isEmpty)
    }

    @Test("Every tag in the library once, first spelling kept, in order")
    func all() {
        #expect(NotebookTags.all(in: [["exam", "Physics"], ["physics", "algebra"]]) == ["algebra", "exam", "Physics"])
    }

    @Test("A very long tag is cut, not refused")
    func long() {
        #expect(NotebookTags.normalised(String(repeating: "a", count: 80))?.count == NotebookTags.maximumLength)
    }
}

// MARK: - The library

@MainActor
@Suite("Organising the library", .serialized)
struct LibraryOrganisationTests {
    private struct Harness {
        let repository: NotebookRepository
        let context: ModelContext
        let container: ModelContainer
        let store: DocumentStore
        let root: URL
    }

    private func makeHarness(root: URL? = nil) -> Harness {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-organise-\(UUID().uuidString)", isDirectory: true)
        let container = ModelContainerFactory.make(inMemory: true)
        let store = DocumentStore(rootURL: root)
        let repository = NotebookRepository(
            context: container.mainContext, store: store,
            entitlements: EntitlementService(listenForUpdates: false)
        )
        return Harness(repository: repository, context: container.mainContext, container: container, store: store, root: root)
    }

    private func shelf(_ name: String, in harness: Harness, parent: UUID? = nil) throws -> Shelf {
        try harness.repository.createShelf(
            name: name, colorHex: ThemePreset.light.accent.hexString, symbolName: "bag", parentID: parent
        )
    }

    @Test("Deleting a shelf loses nothing: its notebooks and shelves move up a level")
    func deleteMovesUp() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let school = try shelf("School", in: harness)
        let biology = try shelf("Biology", in: harness, parent: school.id)
        let cells = try shelf("Cells", in: harness, parent: biology.id)
        let notebook = try await harness.repository.create(
            title: "Mitosis", coverColor: ThemePreset.light.accent, style: PageStyle(template: .ruled), shelfID: biology.id
        )

        try harness.repository.deleteShelf(biology)

        #expect(notebook.shelfID == school.id)
        #expect(cells.parentID == school.id)
        let left = try harness.context.fetch(FetchDescriptor<Shelf>()).map(\.name).sorted()
        #expect(left == ["Cells", "School"])
    }

    @Test("Deleting a top-level shelf takes its notebooks off every shelf, as before")
    func deleteTopLevel() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let top = try shelf("Journal", in: harness)
        let notebook = try await harness.repository.create(
            title: "Monday", coverColor: ThemePreset.light.accent, style: PageStyle(template: .ruled), shelfID: top.id
        )
        try harness.repository.deleteShelf(top)
        #expect(notebook.shelfID == nil)
    }

    @Test("Moving a shelf into its own inside is refused and changes nothing")
    func moveRefusesCycle() throws {
        let harness = makeHarness()
        let school = try shelf("School", in: harness)
        let biology = try shelf("Biology", in: harness, parent: school.id)
        #expect(!harness.repository.moveShelf(school, under: biology.id))
        #expect(school.parentID == nil)
        #expect(harness.repository.moveShelf(biology, under: nil))
        #expect(biology.parentID == nil)
    }

    @Test("Tags are tidied, found by search, and survive a library rebuilt from the packages")
    func tagsTravel() async throws {
        let first = makeHarness()
        defer { try? FileManager.default.removeItem(at: first.root) }
        let notebook = try await first.repository.create(
            title: "Week 3", coverColor: ThemePreset.light.accent, style: PageStyle(template: .ruled)
        )
        first.repository.setTags(["#Exam", "exam", " cell  biology "], for: notebook)
        #expect(notebook.tags == ["Exam", "cell biology"])

        let target = try #require(first.repository.searchTargets().first { $0.id == notebook.id })
        let results = await SearchIndexer(store: first.store).search("exam", across: [target])
        #expect(results.first?.matchesTitle == true, "a tag is searched with the title")

        await first.repository.mirrorInfo([notebook])
        let second = makeHarness(root: first.root)
        _ = await second.repository.reconcileWithDisk()
        let rebuilt = try second.context.fetch(FetchDescriptor<Notebook>()).first { $0.id == notebook.id }
        #expect(rebuilt?.tags == ["Exam", "cell biology"])
    }

    @Test("A description written before tags existed still reads, with no tags")
    func oldInfoReads() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"Old"}"#
        let info = try JSONDecoder().decode(NotebookInfo.self, from: Data(json.utf8))
        #expect(info.tags == nil)
        #expect(Notebook(info: info).tags.isEmpty)
    }

    @Test("Adding one tag to several notebooks skips those that have it")
    func addTagToMany() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let a = try await harness.repository.create(title: "A", coverColor: ThemePreset.light.accent, style: PageStyle(template: .ruled))
        let b = try await harness.repository.create(title: "B", coverColor: ThemePreset.light.accent, style: PageStyle(template: .ruled))
        harness.repository.setTags(["Exam"], for: a)
        harness.repository.addTag("exam", to: [a, b])
        #expect(a.tags == ["Exam"])
        #expect(b.tags == ["exam"])
        harness.repository.removeTagEverywhere("EXAM")
        #expect(a.tags.isEmpty && b.tags.isEmpty)
    }
}
