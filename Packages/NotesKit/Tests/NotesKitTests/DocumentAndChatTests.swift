import ClassMateTheme
import CoreGraphics
import Foundation
import NotesModels
import NotesServices
import SwiftData
import Testing
import UIKit

/// A throwaway document root per test, so nothing leaks between them.
private func temporaryRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmnote-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A one-page PDF, drawn in memory — enough for the import paths to be real.
private func samplePDF(pages: Int = 2) -> Data {
    let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
    let renderer = UIGraphicsPDFRenderer(bounds: bounds)
    return renderer.pdfData { context in
        for index in 0..<pages {
            context.beginPage()
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 20, y: 20 + index * 10, width: 60, height: 30))
        }
    }
}

private func sampleImage(size: CGSize = CGSize(width: 200, height: 120)) -> Data {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }.pngData() ?? Data()
}

@Suite("Document store: page styles and imports")
struct DocumentStyleTests {
    @Test("A document can be created with several identical pages (the quick note)")
    func createsMultiplePages() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        let manifest = try await store.createDocument(id: id, style: .quickNote, pageCount: 2)
        #expect(manifest.pages.count == 2)
        #expect(manifest.pages.allSatisfy { $0.template == .blank })
        #expect(manifest.pages.allSatisfy { $0.pageSize == .a4 })
        #expect(Set(manifest.pages.map(\.id)).count == 2, "each page gets its own id")
    }

    @Test("Updating a page writes every setting and leaves its neighbours alone")
    func updatesOneSetting() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        _ = try await store.createDocument(id: id, style: PageStyle(template: .ruled), pageCount: 2)
        let first = try await store.manifest(for: id).pages[0].id

        let updated = try await store.updatePage(
            notebook: id, page: first, template: .graph,
            lineColorHex: "#112233", lineSpacingSteps: 8,
            pageSize: .letter, orientation: .landscape
        )
        #expect(updated.pages[0].template == .graph)
        #expect(updated.pages[0].lineColorHex == "#112233")
        #expect(updated.pages[0].lineSpacingSteps == 8)
        #expect(updated.pages[0].logicalSize == PageSize.letter.size(orientation: .landscape))
        #expect(updated.pages[1].template == .ruled, "the other page is untouched")

        // Reloading proves it was actually persisted, not just returned.
        let reloaded = try await store.manifest(for: id)
        #expect(reloaded.pages[0].lineColorHex == "#112233")
    }

    @Test("Clearing a colour resets it to auto")
    func clearsColors() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        _ = try await store.createDocument(
            id: id,
            style: PageStyle(template: .ruled, paperColorHex: "#EEEEEE", lineColorHex: "#333333")
        )
        let page = try await store.manifest(for: id).pages[0].id
        let cleared = try await store.updatePage(
            notebook: id, page: page, clearPaperColor: true, clearLineColor: true
        )
        #expect(cleared.pages[0].paperColorHex == nil)
        #expect(cleared.pages[0].lineColorHex == nil)
    }

    @Test("Apply-to-all copies one page's style across the notebook, content intact")
    func appliesStyleToAll() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        _ = try await store.createDocument(id: id, style: PageStyle(template: .ruled), pageCount: 3)
        var manifest = try await store.manifest(for: id)
        let source = manifest.pages[0].id
        let other = manifest.pages[2].id

        // Give the last page some content to prove styling never eats it.
        let element = PageElement(kind: .text, x: 10, y: 10, width: 80, height: 30, text: "keep me")
        _ = try await store.setElements([element], notebook: id, page: other)

        _ = try await store.updatePage(
            notebook: id, page: source, template: .dotGrid,
            lineColorHex: "#446688", lineSpacingSteps: 2,
            pageSize: .a5, orientation: .landscape
        )
        manifest = try await store.applyStyle(of: source, toAllPagesOf: id)

        #expect(manifest.pages.allSatisfy { $0.template == .dotGrid })
        #expect(manifest.pages.allSatisfy { $0.lineColorHex == "#446688" })
        #expect(manifest.pages.allSatisfy { $0.lineSpacingSteps == 2 })
        #expect(manifest.pages.allSatisfy { $0.pageSize == .a5 })
        #expect(manifest.pages.allSatisfy { $0.orientation == .landscape })
        let kept = manifest.pages.first { $0.id == other }
        #expect(kept?.elements.first?.text == "keep me")
    }

    @Test("A new page inherits the whole style of the page it came from")
    func insertInheritsStyle() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        let style = PageStyle(
            template: .cornell, margin: PageMargin(position: .trailing),
            paperColorHex: "#101010", pageSize: .b5, orientation: .landscape,
            lineColorHex: "#99AABB", lineSpacingSteps: 7
        )
        _ = try await store.createDocument(id: id, style: style)
        let result = try await store.insertPage(notebook: id, at: 1, style: style)
        #expect(result.page.template == .cornell)
        #expect(result.page.pageSize == .b5)
        #expect(result.page.orientation == .landscape)
        #expect(result.page.lineColorHex == "#99AABB")
        #expect(result.page.lineSpacingSteps == 7)
        #expect(result.page.margin.position == .trailing)
    }

    @Test("Duplicating a page copies its style, its content and its background")
    func duplicateCopiesEverything() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        _ = try await store.createDocument(
            id: id,
            style: PageStyle(template: .music, pageSize: .a5, lineColorHex: "#556677")
        )
        var manifest = try await store.manifest(for: id)
        let page = manifest.pages[0].id
        let filename = try await store.saveMedia(sampleImage(), notebook: id, fileExtension: "png")
        _ = try await store.updatePage(notebook: id, page: page)
        _ = try await store.setElements(
            [PageElement(kind: .image, x: 0, y: 0, width: 50, height: 50, payloadFilename: filename)],
            notebook: id, page: page
        )

        manifest = try await store.duplicatePage(notebook: id, page: page)
        #expect(manifest.pages.count == 2)
        let copy = manifest.pages[1]
        #expect(copy.id != page)
        #expect(copy.template == .music)
        #expect(copy.pageSize == .a5)
        #expect(copy.lineColorHex == "#556677")
        #expect(copy.elements.count == 1)
    }

    @Test("Importing a PDF makes one annotatable page per PDF page")
    func importsPDF() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        _ = try await store.createDocument(id: id, style: PageStyle(template: .ruled, pageSize: .a4))
        let result = try await store.importPDF(data: samplePDF(pages: 3), notebook: id, at: 0)

        #expect(result.manifest.pages.count == 4, "3 imported + the original page")
        let imported = result.manifest.pages.prefix(3)
        #expect(imported.allSatisfy { $0.backgroundPayloadFilename != nil })
        #expect(imported.allSatisfy { $0.template == .blank })
        #expect(imported.allSatisfy { $0.margin.position == PageMargin.Position.none })
        #expect(imported.allSatisfy { $0.pageSize == .a4 }, "imports inherit the notebook's paper")
        #expect(result.firstPageID == result.manifest.pages[0].id)

        // The rendered background really is on disk under media/.
        let filename = try #require(result.manifest.pages[0].backgroundPayloadFilename)
        #expect(await store.mediaData(notebook: id, filename: filename) != nil)
    }

    @Test("Importing photos makes annotatable pages too")
    func importsImages() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        _ = try await store.createDocument(id: id, style: PageStyle(template: .blank, pageSize: .a4))
        let result = try await store.importImages(
            [sampleImage(), sampleImage(size: CGSize(width: 90, height: 300))],
            notebook: id, at: 0
        )
        #expect(result.manifest.pages.count == 3)
        #expect(result.manifest.pages.prefix(2).allSatisfy { $0.backgroundPayloadFilename != nil })
    }

    @Test("An unreadable import throws instead of leaving empty pages behind")
    func rejectsGarbage() async throws {
        let store = DocumentStore(rootURL: temporaryRoot())
        let id = UUID()
        _ = try await store.createDocument(id: id, style: PageStyle(template: .blank))
        await #expect(throws: (any Error).self) {
            _ = try await store.importPDF(data: Data("not a pdf".utf8), notebook: id)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.importImages([Data("not an image".utf8)], notebook: id)
        }
        #expect(try await store.manifest(for: id).pages.count == 1)
    }
}

@MainActor
@Suite("Saved NOVA chats")
struct NovaChatStoreTests {
    /// Retains the container: a ModelContext does NOT keep it alive, and a
    /// deallocated container traps on the next store operation.
    private final class Harness {
        let container: ModelContainer
        let store: NovaChatStore

        @MainActor
        init() {
            container = ModelContainerFactory.make(inMemory: true)
            store = NovaChatStore(context: container.mainContext)
        }
    }

    @Test("Chats are scoped to their notebook, newest first")
    func scopedToNotebook() {
        let harness = Harness()
        let bookA = UUID()
        let bookB = UUID()

        let first = harness.store.create(notebookID: bookA)
        harness.store.save(first, turns: [NovaChatTurn(role: .user, content: "explain mitosis")])
        let second = harness.store.create(notebookID: bookA)
        harness.store.save(second, turns: [NovaChatTurn(role: .user, content: "quiz me")])
        harness.store.create(notebookID: bookB)
        harness.store.create(notebookID: nil)

        let forA = harness.store.chats(notebookID: bookA)
        #expect(forA.count == 2)
        #expect(harness.store.chats(notebookID: bookB).count == 1)
        #expect(harness.store.chats(notebookID: nil).count == 1, "library chats are their own list")
        #expect(harness.store.mostRecent(notebookID: bookA)?.id == forA[0].id)
    }

    @Test("Saving a transcript titles the chat from the first question")
    func autoTitles() throws {
        let harness = Harness()
        let chat = harness.store.create(notebookID: UUID())
        #expect(chat.title == NovaChat.untitled)

        harness.store.save(chat, turns: [
            NovaChatTurn(role: .user, content: "What is the Krebs cycle?"),
            NovaChatTurn(role: .assistant, content: "It's the stage of respiration…")
        ])
        #expect(chat.title == "What is the Krebs cycle?")
        #expect(chat.turns.count == 2)
        #expect(chat.preview == "It's the stage of respiration…")

        // A later turn doesn't rename a chat the user is already looking for.
        harness.store.save(chat, turns: chat.turns + [NovaChatTurn(role: .user, content: "again")])
        #expect(chat.title == "What is the Krebs cycle?")
    }

    @Test("Long first questions are trimmed into a usable title")
    func trimsLongTitles() {
        let long = String(repeating: "photosynthesis ", count: 12)
        let title = NovaChatTurn.title(from: [NovaChatTurn(role: .user, content: long)])
        #expect(title.count <= 42)
        #expect(title.hasSuffix("…"))

        #expect(NovaChatTurn.title(from: []) == NovaChat.untitled)
        #expect(
            NovaChatTurn.title(from: [NovaChatTurn(role: .assistant, content: "hi")]) == NovaChat.untitled
        )
    }

    @Test("A transcript survives the round trip through storage")
    func transcriptRoundTrips() throws {
        let harness = Harness()
        let chat = harness.store.create(notebookID: UUID())
        let turns = [
            NovaChatTurn(role: .user, content: "Explain this", hasAttachment: true),
            NovaChatTurn(role: .assistant, content: "Line one\nLine two")
        ]
        harness.store.save(chat, turns: turns)

        let restored = chat.turns
        #expect(restored.count == 2)
        #expect(restored[0].hasAttachment)
        #expect(restored[1].content == "Line one\nLine two")
        #expect(restored.map(\.id) == turns.map(\.id))
    }

    @Test("A corrupt transcript reads as empty instead of trapping")
    func corruptTranscript() {
        let harness = Harness()
        let chat = harness.store.create(notebookID: UUID())
        chat.transcript = Data("{ not json".utf8)
        #expect(chat.turns.isEmpty)
        #expect(chat.preview == "No messages yet")
    }

    @Test("Deleting a notebook's chats leaves other notebooks alone")
    func deleteByNotebook() {
        let harness = Harness()
        let doomed = UUID()
        let kept = UUID()
        harness.store.create(notebookID: doomed)
        harness.store.create(notebookID: doomed)
        harness.store.create(notebookID: kept)

        harness.store.deleteChats(notebookID: doomed)
        #expect(harness.store.chats(notebookID: doomed).isEmpty)
        #expect(harness.store.chats(notebookID: kept).count == 1)
    }

    @Test("Renaming ignores blank titles")
    func rename() {
        let harness = Harness()
        let chat = harness.store.create(notebookID: nil, title: "Original")
        harness.store.rename(chat, to: "   ")
        #expect(chat.title == "Original")
        harness.store.rename(chat, to: "  Biology revision ")
        #expect(chat.title == "Biology revision")
    }
}

@MainActor
@Suite("Conversation persistence bridge")
struct NovaConversationBridgeTests {
    /// A provider that never streams — these tests are about the transcript shape,
    /// not the network.
    private struct SilentProvider: AIProvider {
        var isConfigured: Bool { true }
        func streamReply(to messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @Test("Restoring a saved chat rebuilds the visible transcript, system prompt hidden")
    func restores() {
        let conversation = NovaConversation(provider: SilentProvider())
        let turns = [
            NovaChatTurn(role: .user, content: "hello"),
            NovaChatTurn(role: .assistant, content: "hi there")
        ]
        conversation.restore(turns: turns)

        #expect(conversation.visibleMessages.count == 2)
        #expect(conversation.visibleMessages[0].role == .user)
        #expect(conversation.visibleMessages[1].content == "hi there")
        #expect(conversation.messages.first?.role == .system)
    }

    @Test("Stored turns drop empty placeholders so a failed reply is never saved")
    func skipsEmptyTurns() {
        let conversation = NovaConversation(provider: SilentProvider())
        conversation.restore(turns: [
            NovaChatTurn(role: .user, content: "question"),
            NovaChatTurn(role: .assistant, content: "   ")
        ])
        let stored = conversation.storedTurns
        #expect(stored.count == 1)
        #expect(stored[0].role == .user)
    }

    @Test("Reset clears the transcript back to just the system prompt")
    func reset() {
        let conversation = NovaConversation(provider: SilentProvider())
        conversation.restore(turns: [NovaChatTurn(role: .user, content: "x")])
        conversation.reset()
        #expect(conversation.visibleMessages.isEmpty)
        #expect(conversation.storedTurns.isEmpty)
    }
}

@MainActor
@Suite("Library creation flows")
struct LibraryCreationTests {
    private final class Harness {
        let container: ModelContainer
        let store: DocumentStore
        let repository: NotebookRepository

        @MainActor
        init() {
            container = ModelContainerFactory.make(inMemory: true)
            store = DocumentStore(rootURL: temporaryRoot())
            repository = NotebookRepository(
                context: container.mainContext,
                store: store,
                entitlements: EntitlementService()
            )
        }
    }

    private var color: ThemeColor { ThemePreset.matcha.spec.accent }

    @Test("A quick note is a cover plus two blank white pages, instantly")
    func quickNote() async throws {
        let harness = Harness()
        let notebook = try await harness.repository.createQuickNote(coverColor: color)

        #expect(notebook.kind == .notebook)
        #expect(notebook.showsCover)
        #expect(notebook.coverDesign == .default)

        let manifest = try await harness.store.manifest(for: notebook.id)
        #expect(manifest.pages.count == 2)
        #expect(manifest.pages.allSatisfy { $0.template == .blank })
        #expect(manifest.pages.allSatisfy { $0.margin.position == PageMargin.Position.none })
        #expect(manifest.pages.allSatisfy { $0.paperColorHex == PaperPalette.white.color.hexString })
    }

    @Test("A whiteboard is one big landscape board with the cover switched off")
    func whiteboard() async throws {
        let harness = Harness()
        let board = try await harness.repository.create(
            title: "Ideas",
            coverColor: color,
            style: PageStyle(
                template: .grid, margin: PageMargin(position: .none),
                pageSize: .whiteboard, orientation: .landscape
            ),
            kind: .whiteboard,
            showsCover: false
        )
        #expect(board.kind.isSinglePage)
        #expect(!board.showsCover)
        let manifest = try await harness.store.manifest(for: board.id)
        #expect(manifest.pages.count == 1)
        #expect(manifest.pages[0].pageSize == .whiteboard)
        #expect(manifest.pages[0].logicalSize.width > manifest.pages[0].logicalSize.height)
    }

    @Test("A created notebook carries its geometry so new pages match")
    func notebookCarriesStyle() async throws {
        let harness = Harness()
        let style = PageStyle(
            template: .dotGrid, paperColorHex: "#F5F5F5", pageSize: .letter,
            orientation: .landscape, lineColorHex: "#224466", lineSpacingSteps: 7
        )
        let notebook = try await harness.repository.create(
            title: "Physics", coverColor: color, style: style, coverDesign: .marble
        )
        #expect(notebook.coverDesign == .marble)
        #expect(notebook.pageSize == .letter)
        #expect(notebook.orientation == .landscape)
        #expect(notebook.lineColorHex == "#224466")
        #expect(notebook.lineSpacingSteps == 7)
        #expect(notebook.pageStyle == style)
    }

    @Test("An untitled document is named after what it is")
    func defaultTitles() async throws {
        let harness = Harness()
        let board = try await harness.repository.create(
            title: "", coverColor: color, style: PageStyle(), kind: .whiteboard
        )
        let note = try await harness.repository.create(
            title: "", coverColor: color, style: PageStyle(), kind: .notebook
        )
        #expect(board.title == "Whiteboard")
        #expect(note.title == "Untitled")
    }

    @Test("Importing a PDF creates a document of exactly the PDF's pages")
    func importsPDFDocument() async throws {
        let harness = Harness()
        let notebook = try #require(
            try await harness.repository.createFromImport(
                title: "Worksheet", coverColor: color, kind: .document, pdf: samplePDF(pages: 2)
            )
        )
        #expect(notebook.kind == .document)
        let manifest = try await harness.store.manifest(for: notebook.id)
        #expect(manifest.pages.count == 2, "the placeholder page is removed")
        #expect(manifest.pages.allSatisfy { $0.backgroundPayloadFilename != nil })
    }

    @Test("Importing a photo creates a one-page annotatable document")
    func importsImageDocument() async throws {
        let harness = Harness()
        let notebook = try #require(
            try await harness.repository.createFromImport(
                title: "Diagram", coverColor: color, kind: .image, images: [sampleImage()]
            )
        )
        let manifest = try await harness.store.manifest(for: notebook.id)
        #expect(manifest.pages.count == 1)
        #expect(manifest.pages[0].backgroundPayloadFilename != nil)
    }

    @Test("An unreadable import leaves no stub in the library")
    func failedImportCleansUp() async throws {
        let harness = Harness()
        let result = try await harness.repository.createFromImport(
            title: "Broken", coverColor: color, kind: .document, pdf: Data("nope".utf8)
        )
        #expect(result == nil)
        let notebooks = harness.repository.fullSnapshot().notebooks
        #expect(notebooks.isEmpty, "a failed import must not leave an empty notebook behind")
    }

    @Test("A non-page file lands on page one as an openable chip")
    func attachesFile() async throws {
        let harness = Harness()
        let notebook = try await harness.repository.create(
            title: "Data", coverColor: color, style: PageStyle(), kind: .document
        )
        await harness.repository.attachFile(
            Data("id,name\n1,a".utf8), displayName: "roster.csv", fileExtension: "csv",
            to: notebook.id
        )
        let manifest = try await harness.store.manifest(for: notebook.id)
        let element = try #require(manifest.pages.first?.elements.first)
        #expect(element.kind == .file)
        #expect(element.displayName == "roster.csv")
        #expect(element.payloadFilename?.hasSuffix(".csv") == true)
    }

    @Test("Old notebooks migrate to the new fields with sensible defaults")
    func legacyNotebookDefaults() {
        // A Milestone-1 row only ever set these four values.
        let legacy = Notebook(title: "Old", coverColorHex: "#123456", defaultTemplate: .ruled)
        #expect(legacy.kind == .notebook)
        #expect(legacy.coverDesign == .default)
        #expect(legacy.showsCover)
        #expect(legacy.pageSize == .classic)
        #expect(legacy.orientation == .portrait)
        #expect(legacy.lineSpacingSteps == PageLineSpacing.default)
        #expect(legacy.pageStyle.logicalSize == PageGeometry.size)
    }
}
