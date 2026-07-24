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
@Suite("ClassMate networking", .serialized)
struct ClassMateNetworkingTests {
    private func makeClient(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> ClassMateAPIClient {
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClassMateAPIClient(session: URLSession(configuration: config))
    }

    // MARK: API client

    @Test("Login returns the token from {token}")
    func loginSuccess() async throws {
        let client = makeClient { _ in (200, Data(#"{"token":"jwt-abc"}"#.utf8)) }
        let token = try await client.login(identifier: "sam@x.com", password: "pw")
        #expect(token == "jwt-abc")
    }

    @Test("401 maps to invalidCredentials")
    func loginInvalid() async {
        let client = makeClient { _ in (401, Data(#"{"message":"nope"}"#.utf8)) }
        await #expect(throws: APIError.invalidCredentials) {
            try await client.login(identifier: "x", password: "y")
        }
    }

    @Test("me decodes the trimmed profile with role priority")
    func meDecodes() async throws {
        let client = makeClient { _ in
            let json = """
            {"id":"u1","email":"sam@x.com","username":"sam","roles":["STUDENT","TEACHER"],
             "schoolName":"Rise","displayName":"Sam Lee","grade":10}
            """
            return (200, Data(json.utf8))
        }
        let user = try await client.me(token: "jwt")
        #expect(user.username == "sam")
        #expect(user.bestName == "Sam Lee")
        #expect(user.initials == "SL")
        #expect(user.primaryRole == "TEACHER") // TEACHER outranks STUDENT
    }

    @Test("Base URL falls back to the ClassMate production host")
    func baseURL() {
        #expect(ClassMateAPI.defaultBaseURL.host == "pacific-enchantment-production-7a80.up.railway.app")
    }

    // MARK: AuthService

    @MainActor
    private func makeAuth(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> AuthService {
        AuthService(client: makeClient(handler), keychain: InMemorySecretStore())
    }

    @Test @MainActor
    func signInStoresSessionAndProfile() async {
        let service = makeAuth { request in
            if request.url?.path == "/auth/login" {
                return (200, Data(#"{"token":"jwt-1"}"#.utf8))
            }
            return (200, Data(#"{"id":"u1","email":"a@b.com","roles":["STUDENT"],"displayName":"A B"}"#.utf8))
        }
        let ok = await service.signIn(identifier: "a@b.com", password: "pw")
        #expect(ok)
        #expect(service.state == .authenticated)
        #expect(service.user?.bestName == "A B")
        #expect(service.token == "jwt-1")
        service.signOut()
        #expect(service.state == .signedOut)
        #expect(service.token == nil)
    }

    @Test @MainActor
    func signInFailureStaysSignedOut() async {
        let service = makeAuth { _ in (401, Data(#"{"message":"no"}"#.utf8)) }
        let ok = await service.signIn(identifier: "a@b.com", password: "bad")
        #expect(!ok)
        #expect(service.state != .authenticated)
        #expect(service.lastError != nil)
    }

    @Test @MainActor
    func emptyFieldsShortCircuit() async {
        let service = makeAuth { _ in (200, Data()) }
        let ok = await service.signIn(identifier: "  ", password: "")
        #expect(!ok)
        #expect(service.lastError != nil)
    }
}
