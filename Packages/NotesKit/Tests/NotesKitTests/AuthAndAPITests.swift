import Foundation
import Testing
@testable import NotesServices

/// Stub protocol handler so we exercise the real request-building + decoding
/// against canned responses — no network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// One serialized suite for everything that uses the shared URLProtocol handler,
/// so the global stub is never raced across concurrent tests.
@Suite("ClassNotes networking", .serialized)
struct ClassMateNetworkingTests {
    private func stubbedSession(
        _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> URLSession {
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(
        _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> ClassMateAPIClient {
        ClassMateAPIClient(session: stubbedSession(handler))
    }

    private func makeAuthClient(
        _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> ClassNotesAuthClient {
        ClassNotesAuthClient(session: stubbedSession(handler))
    }

    private static let accountJSON = """
    {"id":"11111111-2222-3333-4444-555555555555","email":"sam@x.com",
     "name":"Sam Lee","createdAt":"2026-01-01T10:00:00.123Z"}
    """

    // MARK: - ClassNotes accounts

    @Test("Register posts to /classnotes/auth/register and returns the session")
    func registerReturnsSession() async throws {
        let client = makeAuthClient { request in
            guard request.url?.path == "/classnotes/auth/register", request.httpMethod == "POST" else {
                return (418, Data())
            }
            return (201, Data(#"{"token":"jwt-new","account":\#(Self.accountJSON)}"#.utf8))
        }
        let session = try await client.register(email: "sam@x.com", password: "longenough", name: "Sam Lee")
        #expect(session.token == "jwt-new")
        #expect(session.account.email == "sam@x.com")
        #expect(session.account.displayName == "Sam Lee")
    }

    @Test("Login returns the token and the account together")
    func loginReturnsSession() async throws {
        let client = makeAuthClient { request in
            guard request.url?.path == "/classnotes/auth/login" else { return (418, Data()) }
            return (200, Data(#"{"token":"jwt-abc","account":\#(Self.accountJSON)}"#.utf8))
        }
        let session = try await client.login(email: "sam@x.com", password: "pw")
        #expect(session.token == "jwt-abc")
        #expect(session.account.id == "11111111-2222-3333-4444-555555555555")
    }

    @Test("401 maps to invalidCredentials")
    func loginInvalid() async {
        let client = makeAuthClient { _ in (401, Data(#"{"message":"Incorrect email or password."}"#.utf8)) }
        await #expect(throws: APIError.invalidCredentials) {
            try await client.login(email: "x@y.com", password: "wrong")
        }
    }

    @Test("A refusal the server explained in words keeps those words")
    func registerSurfacesServerMessage() async {
        let client = makeAuthClient { _ in
            (409, Data(#"{"statusCode":409,"message":"That email already has a ClassNotes account."}"#.utf8))
        }
        await #expect(
            throws: APIError.server(
                message: "That email already has a ClassNotes account.", status: 409
            )
        ) {
            try await client.register(email: "sam@x.com", password: "longenough", name: "Sam")
        }
    }

    @Test("Nest's array-of-strings validation message is joined, not dropped")
    func serverMessageJoinsValidationList() {
        let body = Data(#"{"statusCode":400,"message":["email must be an email","password too short"]}"#.utf8)
        #expect(
            ClassNotesAuthClient.serverMessage(from: body)
                == "email must be an email password too short"
        )
    }

    @Test("A body with nothing to say degrades to badResponse, not an empty message")
    func serverMessageAbsentFallsBack() async {
        let client = makeAuthClient { _ in (500, Data("<html>nginx</html>".utf8)) }
        await #expect(throws: APIError.badResponse(status: 500)) {
            try await client.login(email: "sam@x.com", password: "pw")
        }
    }

    @Test("me decodes the account; a 403 reads as not-authenticated")
    func meDecodes() async throws {
        let client = makeAuthClient { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt" else {
                return (401, Data())
            }
            return (200, Data(Self.accountJSON.utf8))
        }
        let account = try await client.me(token: "jwt")
        #expect(account.email == "sam@x.com")
        #expect(account.initial == "S")

        // The role guard refuses with 403, not 401, when a token carries the
        // wrong role — both mean "this session is finished".
        let denied = makeAuthClient { _ in (403, Data()) }
        await #expect(throws: APIError.notAuthenticated) { try await denied.me(token: "stale") }
    }

    @Test("changePassword returns the REPLACEMENT token")
    func changePasswordReturnsReplacement() async throws {
        let client = makeAuthClient { request in
            guard request.url?.path == "/classnotes/auth/change-password" else { return (418, Data()) }
            return (200, Data(#"{"token":"jwt-fresh"}"#.utf8))
        }
        let replacement = try await client.changePassword(current: "old", new: "newpassword", token: "jwt-old")
        #expect(replacement == "jwt-fresh")
    }

    @Test("Deleting an account sends the password and a DELETE")
    func deleteAccountSendsPassword() async throws {
        let client = makeAuthClient { request in
            guard request.httpMethod == "DELETE", request.url?.path == "/classnotes/auth/me" else {
                return (418, Data())
            }
            return (200, Data(#"{"deleted":true}"#.utf8))
        }
        try await client.deleteAccount(password: "pw", token: "jwt")
    }

    @Test("A wrong password cannot delete the account")
    func deleteAccountRejectsWrongPassword() async {
        let client = makeAuthClient { _ in (401, Data(#"{"message":"Incorrect password."}"#.utf8)) }
        await #expect(throws: APIError.invalidCredentials) {
            try await client.deleteAccount(password: "nope", token: "jwt")
        }
    }

    @Test("forgotPassword reports what the server said, which is the same either way")
    func forgotPasswordReportsServerAnswer() async throws {
        let client = makeAuthClient { request in
            guard request.url?.path == "/classnotes/auth/forgot-password" else { return (418, Data()) }
            return (200, Data(#"{"sent":true,"message":"If that email has a ClassNotes account, a reset link is on its way."}"#.utf8))
        }
        let result = try await client.forgotPassword(email: "sam@x.com")
        #expect(result.sent)
        #expect(result.message?.hasPrefix("If that email") == true)
    }

    // MARK: - Account decoding

    @Test("A timestamp without fractional seconds still decodes")
    func accountDecodesPlainTimestamp() throws {
        let json = Data(#"{"id":"a","email":"a@b.com","name":"A B","createdAt":"2026-01-01T10:00:00Z"}"#.utf8)
        let account = try JSONDecoder().decode(ClassNotesAccount.self, from: json)
        #expect(account.createdAt != nil)
    }

    @Test("A missing or unparseable join date is nil, never a failed sign-in")
    func accountToleratesMissingTimestamp() throws {
        let absent = try JSONDecoder().decode(
            ClassNotesAccount.self, from: Data(#"{"id":"a","email":"a@b.com","name":"A"}"#.utf8)
        )
        #expect(absent.createdAt == nil)
        let garbage = try JSONDecoder().decode(
            ClassNotesAccount.self,
            from: Data(#"{"id":"a","email":"a@b.com","name":"A","createdAt":"yesterday"}"#.utf8)
        )
        #expect(garbage.createdAt == nil)
    }

    @Test("A blank name falls back to the email's local part, never an empty heading")
    func accountFallsBackToEmailLocalPart() {
        let account = ClassNotesAccount(id: "a", email: "sam.lee@x.com", name: "   ")
        #expect(account.displayName == "sam.lee")
        #expect(account.initial == "S")
    }

    // MARK: - Library sync client

    @Test("Base URL falls back to the production host")
    func baseURL() {
        #expect(ClassMateAPI.defaultBaseURL.host == "pacific-enchantment-production-7a80.up.railway.app")
    }

    @Test("fetchLibrary decodes notebooks with Postgres's fractional-second timestamps")
    func fetchLibraryDecodes() async throws {
        let client = makeClient { _ in
            let json = """
            {
              "shelves": [],
              "notebooks": [
                {
                  "id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
                  "title": "Physics", "coverColorHex": "#2266DD", "coverImage": null,
                  "template": "ruled", "shelfId": null, "pageCount": 3,
                  "createdAt": "2026-01-01T10:00:00.123Z",
                  "updatedAt": "2026-01-02T11:30:00.456Z"
                }
              ]
            }
            """
            return (200, Data(json.utf8))
        }
        let library = try await client.fetchLibrary(token: "jwt")
        #expect(library.notebooks.count == 1)
        #expect(library.notebooks.first?.title == "Physics")
        #expect(library.notebooks.first?.id == "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d")
    }

    @Test("fetchNotebookPages decodes rendered pages and their attachments")
    func fetchNotebookPagesDecodes() async throws {
        let client = makeClient { _ in
            let json = """
            {
              "pages": [
                {
                  "pageIndex": 0, "dataUrl": "data:image/png;base64,AA==",
                  "attachments": [
                    {"kind": "link", "name": "Docs", "url": "https://example.com"}
                  ]
                }
              ]
            }
            """
            return (200, Data(json.utf8))
        }
        let pages = try await client.fetchNotebookPages(id: "n1", token: "jwt")
        #expect(pages.pages.count == 1)
        #expect(pages.pages.first?.attachments.first?.kind == "link")
        #expect(pages.pages.first?.attachments.first?.url == "https://example.com")
    }

    @Test("A page synced before attachments existed decodes with an empty list, not a throw")
    func fetchNotebookPagesToleratesMissingAttachments() async throws {
        let client = makeClient { _ in
            (200, Data(#"{"pages":[{"pageIndex":0,"dataUrl":"data:image/png;base64,AA==","attachments":[]}]}"#.utf8))
        }
        let pages = try await client.fetchNotebookPages(id: "n1", token: "jwt")
        #expect(pages.pages.first?.attachments.isEmpty == true)
    }

    // MARK: - AuthService

    @MainActor
    private func makeAuth(
        _ handler: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> (AuthService, InMemorySecretStore) {
        let keychain = InMemorySecretStore()
        return (AuthService(client: makeAuthClient(handler), keychain: keychain), keychain)
    }

    @Test @MainActor
    func signInStoresSessionAndAccount() async {
        let (service, _) = makeAuth { _ in
            (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8))
        }
        let ok = await service.signIn(email: "SAM@x.com ", password: "pw")
        #expect(ok)
        #expect(service.state == .authenticated)
        #expect(service.account?.displayName == "Sam Lee")
        #expect(service.token == "jwt-1")
        service.signOut()
        #expect(service.state == .signedOut)
        #expect(service.token == nil)
        #expect(service.account == nil)
    }

    @Test @MainActor
    func signInFailureStaysSignedOut() async {
        let (service, _) = makeAuth { _ in (401, Data(#"{"message":"no"}"#.utf8)) }
        let ok = await service.signIn(email: "a@b.com", password: "bad")
        #expect(!ok)
        #expect(service.state != .authenticated)
        #expect(service.lastError == "Incorrect email or password.")
    }

    @Test @MainActor
    func emptyFieldsShortCircuit() async {
        let (service, _) = makeAuth { _ in (200, Data()) }
        let ok = await service.signIn(email: "  ", password: "")
        #expect(!ok)
        #expect(service.lastError != nil)
    }

    @Test("Sign-up shows the server's own refusal, which says what to change")
    @MainActor
    func registerSurfacesTheServersWording() async {
        let (service, _) = makeAuth { _ in
            (409, Data(#"{"statusCode":409,"message":"That email already has a ClassNotes account."}"#.utf8))
        }
        let ok = await service.register(email: "sam@x.com", name: "Sam", password: "longenough")
        #expect(!ok)
        #expect(service.lastError == "That email already has a ClassNotes account.")
    }

    @Test("Changing the password stores the replacement token, so the device stays signed in")
    @MainActor
    func changePasswordStoresReplacementToken() async {
        let (service, keychain) = makeAuth { request in
            if request.url?.path == "/classnotes/auth/change-password" {
                return (200, Data(#"{"token":"jwt-fresh"}"#.utf8))
            }
            return (200, Data(#"{"token":"jwt-old","account":\#(Self.accountJSON)}"#.utf8))
        }
        _ = await service.signIn(email: "sam@x.com", password: "pw")
        #expect(keychain.get(.authToken) == "jwt-old")
        let ok = await service.changePassword(current: "pw", new: "longenough")
        #expect(ok)
        #expect(keychain.get(.authToken) == "jwt-fresh")
        #expect(service.state == .authenticated)
    }

    @Test("Deleting the account signs out and clears the token")
    @MainActor
    func deleteAccountSignsOut() async {
        let (service, keychain) = makeAuth { request in
            if request.httpMethod == "DELETE" { return (200, Data(#"{"deleted":true}"#.utf8)) }
            return (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8))
        }
        _ = await service.signIn(email: "sam@x.com", password: "pw")
        let ok = await service.deleteAccount(password: "pw")
        #expect(ok)
        #expect(service.state == .signedOut)
        #expect(service.account == nil)
        #expect(keychain.get(.authToken) == nil)
    }

    @Test("A wrong password leaves the account alone and says so")
    @MainActor
    func deleteAccountWithWrongPasswordKeepsTheSession() async {
        let (service, keychain) = makeAuth { request in
            if request.httpMethod == "DELETE" { return (401, Data(#"{"message":"Incorrect password."}"#.utf8)) }
            return (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8))
        }
        _ = await service.signIn(email: "sam@x.com", password: "pw")
        let ok = await service.deleteAccount(password: "wrong")
        #expect(!ok)
        #expect(service.state == .authenticated)
        #expect(keychain.get(.authToken) == "jwt-1")
        #expect(service.lastError == "Incorrect password.")
    }

    @Test("Renaming only sticks locally when the server took it")
    @MainActor
    func updateNameRequiresTheServer() async {
        let (service, _) = makeAuth { request in
            if request.httpMethod == "PATCH" {
                return (200, Data(#"{"id":"11111111-2222-3333-4444-555555555555","email":"sam@x.com","name":"Samantha Lee"}"#.utf8))
            }
            return (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8))
        }
        _ = await service.signIn(email: "sam@x.com", password: "pw")
        let ok = await service.updateName("  Samantha Lee  ")
        #expect(ok)
        #expect(service.account?.displayName == "Samantha Lee")
    }

    @Test("A network blip does NOT sign a cached session out — the notebooks are on disk")
    @MainActor
    func restoreKeepsACachedSessionThroughANetworkFailure() async {
        // Sign in first so there is a cached account and a stored token, then
        // restore against a handler that fails the request outright.
        let keychain = InMemorySecretStore()
        let signedIn = AuthService(
            client: makeAuthClient { _ in
                (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8))
            },
            keychain: keychain
        )
        _ = await signedIn.signIn(email: "sam@x.com", password: "pw")

        StubURLProtocol.handler = nil // every request now fails with a URLError
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let offline = AuthService(
            client: ClassNotesAuthClient(session: URLSession(configuration: config)),
            keychain: keychain
        )
        await offline.restore()
        #expect(offline.state == .authenticated)
        #expect(keychain.get(.authToken) == "jwt-1")
    }

    @Test("The ClassMate token an updating user still holds signs them out cleanly")
    @MainActor
    func restoreSignsOutOnTheOldAccountSystemsToken() async {
        // This is the exact path every existing user takes on first launch after
        // the update: the Keychain holds a ClassMate session, which still
        // authenticates — so it is not a 401 — but carries no CLASSNOTES role,
        // so the role guard answers 403. Reading only 401 as "finished" would
        // leave them staring at a library that can never load.
        let keychain = InMemorySecretStore()
        keychain.set("classmate-era-token", for: .authToken)
        let service = AuthService(client: makeAuthClient { _ in (403, Data()) }, keychain: keychain)
        await service.restore()
        #expect(service.state == .signedOut)
        #expect(service.account == nil)
        #expect(keychain.get(.authToken) == nil)
    }

    @Test("A token the server has stopped honouring DOES sign out")
    @MainActor
    func restoreSignsOutOnA401() async {
        let keychain = InMemorySecretStore()
        let signedIn = AuthService(
            client: makeAuthClient { _ in
                (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8))
            },
            keychain: keychain
        )
        _ = await signedIn.signIn(email: "sam@x.com", password: "pw")

        let revoked = AuthService(client: makeAuthClient { _ in (401, Data()) }, keychain: keychain)
        await revoked.restore()
        #expect(revoked.state == .signedOut)
        #expect(keychain.get(.authToken) == nil)
    }

    // MARK: - Working without an account (D-001)

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "auth-local-first-\(UUID().uuidString)")!
    }

    @Test("A first launch shows sign-in; continuing without an account opens the library, and stays open")
    @MainActor
    func continueWithoutAccountOpensTheLibrary() async {
        let defaults = isolatedDefaults()
        let keychain = InMemorySecretStore()
        let fresh = AuthService(client: makeAuthClient { _ in (500, Data()) }, keychain: keychain, defaults: defaults)
        await fresh.restore()
        #expect(fresh.state == .signedOut)
        #expect(!fresh.libraryIsOpen, "a new device is offered the choice first")

        fresh.continueWithoutAccount()
        #expect(fresh.libraryIsOpen)

        let relaunched = AuthService(client: makeAuthClient { _ in (500, Data()) }, keychain: keychain, defaults: defaults)
        await relaunched.restore()
        #expect(relaunched.libraryIsOpen, "the choice survives a relaunch")
        #expect(relaunched.signedOutNotice == nil)
    }

    @Test("A session the server stops honouring keeps the library open and says why")
    @MainActor
    func rejectedSessionKeepsTheLibraryOpen() async {
        let defaults = isolatedDefaults()
        let keychain = InMemorySecretStore()
        let signedIn = AuthService(
            client: makeAuthClient { _ in (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8)) },
            keychain: keychain, defaults: defaults
        )
        _ = await signedIn.signIn(email: "sam@x.com", password: "pw")

        let revoked = AuthService(client: makeAuthClient { _ in (401, Data()) }, keychain: keychain, defaults: defaults)
        await revoked.restore()
        #expect(revoked.state == .signedOut)
        #expect(keychain.get(.authToken) == nil)
        #expect(revoked.libraryIsOpen, "a student is never locked out of their own notes")
        #expect(revoked.signedOutNotice != nil)
    }

    @Test("Signing out on purpose shows sign-in again (which offers to carry on without one)")
    @MainActor
    func deliberateSignOutShowsSignIn() async {
        let defaults = isolatedDefaults()
        let service = AuthService(
            client: makeAuthClient { _ in (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8)) },
            keychain: InMemorySecretStore(), defaults: defaults
        )
        service.continueWithoutAccount()
        _ = await service.signIn(email: "sam@x.com", password: "pw")
        #expect(service.libraryIsOpen)
        service.signOut()
        #expect(!service.libraryIsOpen)
        #expect(service.signedOutNotice == nil)
    }

    @Test("Deleting the account leaves the library open: the notebooks are the user's own files")
    @MainActor
    func deletingTheAccountKeepsTheLibraryOpen() async {
        let service = AuthService(
            client: makeAuthClient { request in
                if request.httpMethod == "DELETE" { return (200, Data("{}".utf8)) }
                return (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8))
            },
            keychain: InMemorySecretStore(), defaults: isolatedDefaults()
        )
        _ = await service.signIn(email: "sam@x.com", password: "pw")
        let deleted = await service.deleteAccount(password: "pw")
        #expect(deleted)
        #expect(service.state == .signedOut)
        #expect(service.libraryIsOpen)
    }

    @Test("Signing in mid-session asks the app to sync at once")
    @MainActor
    func signingInRunsTheSignInHook() async {
        let service = AuthService(
            client: makeAuthClient { _ in (200, Data(#"{"token":"jwt-1","account":\#(Self.accountJSON)}"#.utf8)) },
            keychain: InMemorySecretStore(), defaults: isolatedDefaults()
        )
        service.continueWithoutAccount()
        var syncs = 0
        service.onSignIn = { syncs += 1 }
        _ = await service.signIn(email: "sam@x.com", password: "pw")
        #expect(syncs == 1)
        _ = await service.signIn(email: "sam@x.com", password: "wrong-but-stubbed-ok")
        #expect(syncs == 2)
    }
}
