import Foundation
import NotesModels

/// The backend contract this app depends on — the same server that powers the
/// ClassMate app, which is where the `/classnotes/*` module lives.
///
/// Sharing a server is NOT sharing an account space: ClassNotes has its own
/// sign-in at `/classnotes/auth/*` (`ClassNotesAuthClient`), and nothing here
/// touches ClassMate's `/auth/*` any more.
public enum ClassMateAPI {
    /// Production API (from ClassMate's `env.dart` web/default). Overridable via
    /// the `CM_API_BASE_URL` Info.plist/launch argument for staging.
    public static let defaultBaseURL = URL(
        string: "https://pacific-enchantment-production-7a80.up.railway.app"
    )!

    public static func baseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CM_API_BASE_URL"],
           let url = URL(string: override.trimmingCharacters(in: .whitespaces)),
           !override.isEmpty {
            return url
        }
        if let override = Bundle.main.object(forInfoDictionaryKey: "CMApiBaseURL") as? String,
           let url = URL(string: override), !override.isEmpty {
            return url
        }
        return defaultBaseURL
    }
}

public enum APIError: Error, Equatable, Sendable {
    case invalidCredentials
    case badResponse(status: Int)
    case decoding
    case network
    case notAuthenticated
    /// A refusal the SERVER explained in words worth showing the user —
    /// "That email already has a ClassNotes account", "Password must be at
    /// least 8 characters". Sign-up is the case that needs it: those messages
    /// are instructions, and a client that collapsed them into its own
    /// "something went wrong" would throw away the only thing that tells the
    /// user what to do differently. Carries the status too, so a caller can
    /// still branch on the code it cares about.
    case server(message: String, status: Int)

    /// `.server` when the body actually explained itself, plain `.badResponse`
    /// when it did not — so no caller has to render an empty message.
    public static func serverMessage(_ message: String?, status: Int) -> APIError {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .badResponse(status: status)
        }
        return .server(message: message, status: status)
    }

    /// The status behind any failure that has one.
    public var status: Int? {
        switch self {
        case .badResponse(let status): status
        case .server(_, let status): status
        case .notAuthenticated: 401
        case .invalidCredentials: 401
        case .decoding, .network: nil
        }
    }
}

/// What the ClassMate ClassNotes tab changed, for this device to apply.
///
/// The library mirror is push-only in the normal case, so managing notebooks from
/// ClassMate needs this one channel back: without it a delete there would be
/// undone by the next launch's push, and a rename would silently revert.
public struct LibraryChanges: Decodable, Sendable, Equatable {
    /// Notebooks deleted in ClassMate. This device removes its local copies.
    public let deletedIds: [String]
    /// Notebooks renamed / re-shelved in ClassMate.
    public let edited: [Edit]

    public struct Edit: Decodable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let shelfId: String?
        public let coverColorHex: String

        public init(id: String, title: String, shelfId: String?, coverColorHex: String) {
            self.id = id
            self.title = title
            self.shelfId = shelfId
            self.coverColorHex = coverColorHex
        }
    }

    public init(deletedIds: [String], edited: [Edit]) {
        self.deletedIds = deletedIds
        self.edited = edited
    }

    /// Every id in the payload — what gets acknowledged once applied.
    public var allIDs: [String] { deletedIds + edited.map(\.id) }

    public var isEmpty: Bool { deletedIds.isEmpty && edited.isEmpty }
}

/// The full remote library for the signed-in account — `GET /classnotes/library`.
/// Used to discover notebooks that exist on the account but not on THIS device
/// yet (the other half of the mirror `pushAll` builds): a notebook drawn purely
/// on the iPad has no local row on the iPhone until this is applied. Shelves
/// aren't modeled here — this channel is additive to notebooks only.
public struct RemoteLibrary: Decodable, Sendable, Equatable {
    public let notebooks: [Entry]

    public struct Entry: Decodable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let coverColorHex: String
        public let coverImage: String?
        public let template: String       // PageTemplate.rawValue
        public let shelfId: String?
        public let pageCount: Int
        public let createdAt: Date
        public let updatedAt: Date
    }
}

/// One notebook's rendered pages — `GET /classnotes/notebooks/:id/pages`. What
/// a device with no local ink package (a remote-only notebook) shows instead:
/// the flat render, plus whatever's playable/openable on it.
public struct RemoteNotebookPages: Decodable, Sendable, Equatable {
    public let pages: [Page]

    public struct Page: Decodable, Sendable, Equatable {
        public let pageIndex: Int
        /// `data:image/png;base64,...`
        public let dataUrl: String
        public let attachments: [Attachment]
    }

    /// Mirrors `NotebookPageAttachment` — `kind` is `audio`, `file` or `link`.
    public struct Attachment: Decodable, Sendable, Equatable {
        public let kind: String
        public let name: String
        public let durationSeconds: Double?
        public let dataUrl: String?
        public let url: String?
    }
}

/// Upload body for `PUT /classnotes/notebooks/:id` — the notebook metadata the
/// ClassMate "ClassNotes" tab renders. The id travels in the URL, so it is NOT
/// part of the body (the backend rejects unknown fields).
public struct NotebookSyncBody: Encodable, Sendable {
    public let title: String
    public let coverColorHex: String
    public let template: String      // PageTemplate.rawValue
    public let shelfId: String?      // nil = unfiled
    public let pageCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    /// The rendered cover — the cover page's artwork with whatever the user drew
    /// on it — as a PNG data URL, so ClassMate shows the SAME cover the iPad
    /// shows. `nil` when nothing has been rendered yet (ClassMate then falls back
    /// to drawing the cover from `coverColorHex`).
    public let coverImage: String?

    public init(
        title: String, coverColorHex: String, template: String,
        shelfId: String?, pageCount: Int, createdAt: Date, updatedAt: Date,
        coverImage: String? = nil
    ) {
        self.title = title
        self.coverColorHex = coverColorHex
        self.template = template
        self.shelfId = shelfId
        self.pageCount = pageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverImage = coverImage
    }
}

/// One playable / openable thing on a page, uploaded alongside the rendered
/// image so the ClassMate ClassNotes tab can listen to voice notes and open files
/// and links — not just look at a flat picture of the page.
///
/// `kind` is `audio`, `file` or `link`. Audio and files travel as data URLs; links
/// carry their address in `url`.
public struct NotebookPageAttachment: Encodable, Sendable {
    /// Payloads above this size are skipped: the request has to stay inside the
    /// backend's JSON body limit, and a page render is already in there.
    public static let maximumPayloadBytes = 6 * 1024 * 1024

    public let kind: String
    public let name: String
    public let durationSeconds: Double?
    public let dataUrl: String?
    public let url: String?

    public init(
        kind: String,
        name: String,
        durationSeconds: Double? = nil,
        dataUrl: String? = nil,
        url: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.durationSeconds = durationSeconds
        self.dataUrl = dataUrl
        self.url = url
    }

    /// A conservative MIME type for a file extension, so ClassMate can hand the
    /// payload to the right viewer.
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        case "gif": "image/gif"
        case "txt", "md": "text/plain"
        case "csv": "text/csv"
        case "json": "application/json"
        case "m4a", "aac": "audio/m4a"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "mp4", "mov": "video/mp4"
        case "doc", "docx": "application/msword"
        case "ppt", "pptx": "application/vnd.ms-powerpoint"
        case "xls", "xlsx": "application/vnd.ms-excel"
        case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }
}

/// One rendered page image for content sync. `dataUrl` is a
/// `data:image/png;base64,…` string; `attachments` are the page's voice notes,
/// files and links.
public struct NotebookPageImage: Encodable, Sendable {
    public let pageIndex: Int
    public let dataUrl: String
    public let attachments: [NotebookPageAttachment]

    public init(
        pageIndex: Int, dataUrl: String, attachments: [NotebookPageAttachment] = []
    ) {
        self.pageIndex = pageIndex
        self.dataUrl = dataUrl
        self.attachments = attachments
    }
}

/// Upload body for `PUT /classnotes/notebooks/:id/pages` — the rendered page
/// images the ClassMate ClassNotes tab shows as real content.
public struct NotebookPagesBody: Encodable, Sendable {
    public let pages: [NotebookPageImage]
    public let pageCount: Int
    public init(pages: [NotebookPageImage], pageCount: Int) {
        self.pages = pages
        self.pageCount = pageCount
    }
}

/// Upload body for `PUT /classnotes/shelves/:id`.
public struct ShelfSyncBody: Encodable, Sendable {
    public let name: String
    public let colorHex: String
    public let symbolName: String
    public let sortIndex: Int
    public let createdAt: Date

    public init(name: String, colorHex: String, symbolName: String, sortIndex: Int, createdAt: Date) {
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// The backend client for everything a signed-in notebook needs: the library
/// mirror, page renders, synced settings and NOVA. It holds NO sign-in calls —
/// accounts are `ClassNotesAuthClient`'s job — and every method here takes a
/// Bearer token it does not care about the origin of, because `/classnotes/*`
/// scopes off the token's subject and nothing else. Injectable `URLSession`
/// keeps it unit-testable with a stub protocol handler.
public struct ClassMateAPIClient: Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = ClassMateAPI.baseURL()) {
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - ClassNotes library sync (Bearer)

    /// `PUT /classnotes/notebooks/:id` — upsert one notebook's metadata.
    public func putNotebook(id: String, body: NotebookSyncBody, token: String) async throws {
        try await putJSON(path: "/classnotes/notebooks/\(id)", body: body, token: token)
    }

    /// `PUT /classnotes/notebooks/:id/pages` — upload rendered page images so
    /// the ClassMate ClassNotes tab shows real content, not blank paper.
    public func putNotebookPages(id: String, body: NotebookPagesBody, token: String) async throws {
        try await putJSON(path: "/classnotes/notebooks/\(id)/pages", body: body, token: token)
    }

    /// `GET /classnotes/changes` — what the ClassMate ClassNotes tab changed since
    /// this device last acknowledged: notebooks deleted there, and notebooks
    /// renamed / re-shelved there. Pulled at launch BEFORE pushing, so a rename
    /// made in ClassMate isn't overwritten by the older local copy.
    public func fetchLibraryChanges(token: String) async throws -> LibraryChanges {
        let (data, status) = try await send(
            request(path: "/classnotes/changes", method: "GET", token: token)
        )
        try ensureSuccess(status)
        guard let decoded = try? JSONDecoder().decode(LibraryChanges.self, from: data) else {
            throw APIError.decoding
        }
        return decoded
    }

    /// `POST /classnotes/changes/ack` — these ids are applied locally, so the
    /// server can purge the tombstones and hand authority back to this device.
    public func acknowledgeChanges(ids: [String], token: String) async throws {
        guard !ids.isEmpty else { return }
        var req = request(path: "/classnotes/changes/ack", method: "POST", token: token)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids])
        let (_, status) = try await send(req)
        try ensureSuccess(status)
    }

    /// `GET /classnotes/library` — every notebook on the account, so a device
    /// can discover ones it doesn't have a local copy of yet.
    public func fetchLibrary(token: String) async throws -> RemoteLibrary {
        let (data, status) = try await send(
            request(path: "/classnotes/library", method: "GET", token: token)
        )
        try ensureSuccess(status)
        guard let decoded = try? Self.settingsDecoder.decode(RemoteLibrary.self, from: data) else {
            throw APIError.decoding
        }
        return decoded
    }

    /// `GET /classnotes/notebooks/:id/pages` — the rendered pages for one
    /// notebook, for a device with no local ink package to draw from.
    public func fetchNotebookPages(id: String, token: String) async throws -> RemoteNotebookPages {
        let (data, status) = try await send(
            request(path: "/classnotes/notebooks/\(id)/pages", method: "GET", token: token)
        )
        try ensureSuccess(status)
        guard let decoded = try? JSONDecoder().decode(RemoteNotebookPages.self, from: data) else {
            throw APIError.decoding
        }
        return decoded
    }

    /// `DELETE /classnotes/notebooks/:id`.
    public func deleteNotebook(id: String, token: String) async throws {
        let (_, status) = try await send(request(path: "/classnotes/notebooks/\(id)", method: "DELETE", token: token))
        try ensureSuccess(status)
    }

    /// `PUT /classnotes/shelves/:id` — upsert one shelf.
    public func putShelf(id: String, body: ShelfSyncBody, token: String) async throws {
        try await putJSON(path: "/classnotes/shelves/\(id)", body: body, token: token)
    }

    /// `DELETE /classnotes/shelves/:id`.
    public func deleteShelf(id: String, token: String) async throws {
        let (_, status) = try await send(request(path: "/classnotes/shelves/\(id)", method: "DELETE", token: token))
        try ensureSuccess(status)
    }

    // MARK: - Settings (the same account on another device)

    /// `PUT /classnotes/settings` — this device's setup, so signing in on a
    /// second one hands the user the app they already configured. The server
    /// keeps the blob opaque: it is the app's own settings, and the backend has
    /// no business knowing what a pen's taper is.
    public func putSettings(_ settings: DeviceSettings, token: String) async throws {
        var req = request(path: "/classnotes/settings", method: "PUT", token: token)
        req.httpBody = try Self.settingsEncoder.encode(settings)
        let (_, status) = try await send(req)
        try ensureSuccess(status)
    }

    /// `GET /classnotes/settings` — nil when the account has never saved any,
    /// which is the normal first-run answer and not an error.
    public func fetchSettings(token: String) async throws -> DeviceSettings? {
        let (data, status) = try await send(
            request(path: "/classnotes/settings", method: "GET", token: token)
        )
        if status == 404 { return nil }
        try ensureSuccess(status)
        struct Envelope: Decodable { let settings: DeviceSettings? }
        if let envelope = try? Self.settingsDecoder.decode(Envelope.self, from: data) {
            return envelope.settings
        }
        return try? Self.settingsDecoder.decode(DeviceSettings.self, from: data)
    }

    /// Dates on this route are ISO-8601 strings, not Foundation's default
    /// seconds-since-2001 doubles — the server validates and stores a real
    /// timestamp, and a bare number is neither readable in the database nor
    /// something a non-Apple client could make sense of.
    static let settingsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Reading back is deliberately more forgiving than writing: Postgres hands
    /// its timestamps out through `toISOString()`, which includes milliseconds,
    /// and Foundation's stock `.iso8601` strategy rejects a fractional second
    /// outright. Accepting both spellings is the difference between settings
    /// that sync and settings that silently never arrive.
    static let settingsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { input in
            let text = try input.singleValueContainer().decode(String.self)
            guard let date = withFraction.date(from: text) ?? plain.date(from: text) else {
                throw APIError.decoding
            }
            return date
        }
        return decoder
    }()

    // MARK: - NOVA note assistant (Bearer)

    /// `POST /classnotes/ai` `{task:"beautify", text}` → `{answer}`. Returns the
    /// tidied-up version of the student's own note text. The model key lives
    /// server-side; the app authenticates with the session token.
    public func beautify(text: String, token: String) async throws -> String {
        try await notesAI(task: "beautify", text: text, token: token)
    }

    /// `POST /classnotes/ai` `{task:"explain", text}` → `{answer}`.
    public func explainNote(text: String, token: String) async throws -> String {
        try await notesAI(task: "explain", text: text, token: token)
    }

    private func notesAI(task: String, text: String, token: String) async throws -> String {
        var req = request(path: "/classnotes/ai", method: "POST", token: token)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["task": task, "text": text])
        let (data, status) = try await send(req)
        try ensureSuccess(status)
        struct AnswerResponse: Decodable { let answer: String }
        guard let decoded = try? JSONDecoder().decode(AnswerResponse.self, from: data) else {
            throw APIError.decoding
        }
        return decoded.answer
    }

    // MARK: - Plumbing

    private func putJSON<Body: Encodable>(path: String, body: Body, token: String) async throws {
        var req = request(path: path, method: "PUT", token: token)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(body)
        let (_, status) = try await send(req)
        try ensureSuccess(status)
    }

    private func ensureSuccess(_ status: Int) throws {
        if status == 401 { throw APIError.notAuthenticated }
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
    }

    private func request(path: String, method: String, token: String?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (data, status)
        } catch {
            throw APIError.network
        }
    }
}
