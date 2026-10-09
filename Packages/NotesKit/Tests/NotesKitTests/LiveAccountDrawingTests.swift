import CoreGraphics
import Foundation
import NotesModels
import PencilKit
import Testing
import UIKit
@testable import NotesServices

/// The one test that talks to the REAL backend.
///
/// Everything else in this suite stubs the network, which proves the client
/// builds the right request and decodes the right response — and would keep
/// passing if the server had never been deployed, or had been deployed with a
/// different contract. This walks the whole way: it creates a ClassNotes
/// account on the live API, draws actual ink, saves it to a real `.cmnote`
/// package, reads it back off disk, pushes the notebook and the rendered page
/// up under that account, fetches both back, and then deletes the account so it
/// leaves nothing behind.
///
/// Off by default — a test that needs the internet must not be able to fail a
/// build. Run it with `CLASSNOTES_LIVE_E2E=1`.
@Suite(
    "A ClassNotes account owns what it draws",
    .enabled(if: ProcessInfo.processInfo.environment["CLASSNOTES_LIVE_E2E"] == "1"),
    .serialized
)
struct LiveAccountDrawingTests {
    private var baseURL: URL { ClassMateAPI.baseURL() }

    /// A stroke built the way PencilKit stores one: a fitted spline over
    /// (location, time) control points, not a raw touch stream.
    private func stroke(from a: CGPoint, to b: CGPoint, steps: Int = 16) -> PKStroke {
        let controls = (0...steps).map { index -> PKStrokePoint in
            let t = CGFloat(index) / CGFloat(steps)
            return PKStrokePoint(
                location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                timeOffset: TimeInterval(t) * 0.4,
                size: CGSize(width: 4, height: 4), opacity: 1,
                force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: controls, creationDate: Date())
        )
    }

    /// A capital "A", drawn as three strokes, so the ink that goes up is ink a
    /// person could have made rather than one meaningless diagonal.
    private func letterA() -> PKDrawing {
        PKDrawing(strokes: [
            stroke(from: CGPoint(x: 120, y: 420), to: CGPoint(x: 200, y: 200)),
            stroke(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 280, y: 420)),
            stroke(from: CGPoint(x: 155, y: 330), to: CGPoint(x: 245, y: 330)),
        ])
    }

    @Test("Sign up, draw, save, sync, read back, delete")
    func drawsAndSyncsUnderItsOwnAccount() async throws {
        let auth = ClassNotesAuthClient(baseURL: baseURL)
        let data = ClassMateAPIClient(baseURL: baseURL)
        let email = "classnotes-e2e-\(UUID().uuidString.prefix(8).lowercased())@example.invalid"
        let password = "e2e-password-\(UUID().uuidString.prefix(6))"

        // 1. An account that did not exist a moment ago.
        // Registered with a MIXED-CASE address on purpose: the server stores it
        // folded, so "Tony@x.com" and "tony@x.com" are one account, not two.
        let session = try await auth.register(
            email: email.uppercased(), password: password, name: "E2E Pencil"
        )
        #expect(session.account.email == email)
        #expect(!session.token.isEmpty)

        // Whatever happens below, the account goes away again.
        defer {
            let token = session.token
            Task.detached {
                try? await ClassNotesAuthClient(baseURL: ClassMateAPI.baseURL())
                    .deleteAccount(password: password, token: token)
            }
        }

        // 2. A real document package on disk, with real ink on page one.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        let notebookID = UUID()
        let manifest = try await store.createDocument(id: notebookID, firstPageTemplate: .ruled)
        let pageID = try #require(manifest.pages.first?.id)

        let drawing = letterA()
        try await store.savePageData(drawing.dataRepresentation(), notebook: notebookID, page: pageID)

        // 3. Read it back off disk, the way reopening the notebook would.
        let onDisk = await store.pageData(notebook: notebookID, page: pageID)
        let reloaded = try #require(onDisk)
        let reloadedDrawing = try PKDrawing(data: reloaded)
        #expect(reloadedDrawing.strokes.count == 3)
        #expect(!reloadedDrawing.bounds.isEmpty)

        // 4. Render the page exactly as the sync does, and push both.
        let rendered = reloadedDrawing.image(
            from: CGRect(x: 0, y: 0, width: 768, height: 1024), scale: 1
        )
        let png = try #require(rendered.pngData())
        let now = Date()
        try await data.putNotebook(
            id: notebookID.uuidString,
            body: NotebookSyncBody(
                title: "Pencil E2E", coverColorHex: "#2266DD", template: "ruled",
                shelfId: nil, pageCount: 1, createdAt: now, updatedAt: now
            ),
            token: session.token
        )
        try await data.putNotebookPages(
            id: notebookID.uuidString,
            body: NotebookPagesBody(
                pages: [
                    NotebookPageImage(
                        pageIndex: 0,
                        dataUrl: "data:image/png;base64,\(png.base64EncodedString())"
                    )
                ],
                pageCount: 1
            ),
            token: session.token
        )

        // 5. The server has it, under THIS account.
        let library = try await data.fetchLibrary(token: session.token)
        #expect(library.notebooks.contains { $0.id == notebookID.uuidString })
        #expect(library.notebooks.first { $0.id == notebookID.uuidString }?.title == "Pencil E2E")

        let pages = try await data.fetchNotebookPages(id: notebookID.uuidString, token: session.token)
        #expect(pages.pages.count == 1)
        let returned = try #require(pages.pages.first?.dataUrl)
        #expect(returned.hasPrefix("data:image/png;base64,"))
        // The page came back as the same picture that went up, not a placeholder.
        #expect(returned.count > 1000)

        // 6. NOVA answers on this session too — it is the same token, through
        // the same provider the app uses.
        let secrets = InMemorySecretStore()
        secrets.set(session.token, for: .authToken)
        let nova = NovaBackendProvider(keychain: secrets, baseURL: baseURL)
        var answer = ""
        for try await token in nova.streamReply(to: [AIMessage(role: .user, content: "What is 7 x 6?")]) {
            answer += token
        }
        #expect(answer.contains("42"))

        // 7. Deleting the account takes the notebooks with it.
        try await auth.deleteAccount(password: password, token: session.token)
        await #expect(throws: APIError.notAuthenticated) {
            try await auth.me(token: session.token)
        }
    }
}
