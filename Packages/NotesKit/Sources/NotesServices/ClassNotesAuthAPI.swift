import Foundation

/// What `/classnotes/auth/forgot-password` answered.
///
/// `sent` only ever means "the request was accepted" — the server deliberately
/// replies the same way for an address with an account and one without, so that
/// the screen cannot be used to find out who has signed up. `message` is the
/// server's own wording and is rendered as-is.
public struct PasswordResetResult: Sendable, Equatable {
    public let sent: Bool
    public let message: String?

    public init(sent: Bool, message: String?) {
        self.sent = sent
        self.message = message
    }
}

/// A ClassNotes account — the app's OWN identity, not a ClassMate one.
///
/// ClassNotes used to sign in with a ClassMate school account, because
/// ClassMate's backend was already authenticating the library sync. That was
/// wrong in both directions: someone who just wanted a notebook app had to be
/// enrolled in a school platform to open it, and the sign-in screen had to
/// explain an account they had never heard of. An account here is email, a
/// password and a name, and nothing else is asked for.
public struct ClassNotesAccount: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let email: String
    public let name: String
    public let createdAt: Date?

    public init(id: String, email: String, name: String, createdAt: Date? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.createdAt = createdAt
    }

    /// What the profile screen shows as the heading. Falls back to the email's
    /// local part so a row with a blank name never renders as an empty title.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return String(email.split(separator: "@").first ?? "")
    }

    /// The letter in the avatar circle.
    public var initial: String {
        displayName.first.map { String($0).uppercased() } ?? "?"
    }

    /// `createdAt` arrives as an ISO-8601 string with fractional seconds from
    /// Nest/Prisma (`2026-10-03T01:23:45.678Z`), which `.iso8601` alone refuses.
    /// It is decoded leniently and is optional throughout: the join date is a
    /// nicety on the profile screen, and failing a whole sign-in because a
    /// timestamp had a different number of decimal places would be absurd.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        if let raw = try? container.decode(String.self, forKey: .createdAt) {
            createdAt = Self.parseDate(raw)
        } else {
            createdAt = nil
        }
    }

    static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, name, createdAt
    }
}

/// ClassNotes' own `/classnotes/auth/*` endpoints.
///
/// The session it returns is the same bearer token the rest of the app already
/// sends: `/classnotes/notebooks`, `/classnotes/settings` and NOVA's
/// `/classnotes/ai` all accept it unchanged, because the server resolves a
/// ClassNotes token to an owner id exactly the way it resolves a ClassMate one.
/// That is the entire reason this was built as a second identity on the existing
/// API rather than a second service.
public struct ClassNotesAuthClient: Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = ClassMateAPI.baseURL()) {
        self.session = session
        self.baseURL = baseURL
    }

    /// What a successful sign-in or sign-up hands back.
    public struct Session: Sendable, Equatable {
        public let token: String
        public let account: ClassNotesAccount
    }

    /// The shape every `/classnotes/auth` success body shares.
    private struct SessionResponse: Decodable {
        let token: String
        let account: ClassNotesAccount
    }

    /// Nest's error body: `{ statusCode, message, error }`, where `message` is a
    /// string or an array of validation strings. Surfacing the server's own text
    /// matters here — "That email already has a ClassNotes account" is an
    /// instruction, and collapsing it into "something went wrong" throws away the
    /// one thing the user needed to read.
    static func serverMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let text = json["message"] as? String, !text.isEmpty { return text }
        if let list = json["message"] as? [String] {
            let joined = list.joined(separator: " ")
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    public func register(email: String, password: String, name: String) async throws -> Session {
        var body = ["email": email, "password": password]
        if !name.isEmpty { body["name"] = name }
        return try await session(path: "/classnotes/auth/register", body: body)
    }

    public func login(email: String, password: String) async throws -> Session {
        try await session(
            path: "/classnotes/auth/login",
            body: ["email": email, "password": password]
        )
    }

    public func me(token: String) async throws -> ClassNotesAccount {
        let (data, status) = try await send(request(path: "/classnotes/auth/me", method: "GET", token: token))
        if status == 401 || status == 403 { throw APIError.notAuthenticated }
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
        guard let account = try? decoder.decode(ClassNotesAccount.self, from: data) else {
            throw APIError.decoding
        }
        return account
    }

    public func updateName(_ name: String, token: String) async throws -> ClassNotesAccount {
        let (data, status) = try await send(
            request(path: "/classnotes/auth/me", method: "PATCH", token: token, body: ["name": name])
        )
        if status == 401 || status == 403 { throw APIError.notAuthenticated }
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
        guard let account = try? decoder.decode(ClassNotesAccount.self, from: data) else {
            throw APIError.decoding
        }
        return account
    }

    /// Returns the REPLACEMENT token. A password change revokes every token
    /// issued earlier, this one included, so a client that kept the old string
    /// would sign itself out on its next request.
    public func changePassword(
        current: String, new: String, token: String
    ) async throws -> String {
        let (data, status) = try await send(
            request(
                path: "/classnotes/auth/change-password", method: "POST", token: token,
                body: ["currentPassword": current, "newPassword": new]
            )
        )
        if status == 401 { throw APIError.invalidCredentials }
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
        struct TokenResponse: Decodable { let token: String }
        guard let decoded = try? decoder.decode(TokenResponse.self, from: data) else {
            throw APIError.decoding
        }
        return decoded.token
    }

    /// Deletes the account and every notebook it owns on the server. The local
    /// documents are the caller's problem — see `AuthService.deleteAccount`.
    public func deleteAccount(password: String, token: String) async throws {
        let (_, status) = try await send(
            request(
                path: "/classnotes/auth/me", method: "DELETE", token: token,
                body: ["password": password]
            )
        )
        if status == 401 { throw APIError.invalidCredentials }
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
    }

    /// Asks for a reset link. The server answers the same way whether or not the
    /// address has an account, so this cannot report "no such account" — and
    /// must not pretend to.
    public func forgotPassword(email: String) async throws -> PasswordResetResult {
        let (data, status) = try await send(
            request(
                path: "/classnotes/auth/forgot-password", method: "POST", token: nil,
                body: ["email": email]
            )
        )
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
        struct SentResponse: Decodable { let sent: Bool?; let message: String? }
        let decoded = try? decoder.decode(SentResponse.self, from: data)
        return .init(sent: decoded?.sent ?? true, message: decoded?.message)
    }

    // MARK: - Plumbing

    private var decoder: JSONDecoder { JSONDecoder() }

    /// Register and login differ only in their path, and both can fail with a
    /// message worth showing, so they share one body.
    private func session(path: String, body: [String: String]) async throws -> Session {
        let (data, status) = try await send(
            request(path: path, method: "POST", token: nil, body: body)
        )
        if status == 401 { throw APIError.invalidCredentials }
        guard (200..<300).contains(status) else {
            throw APIError.serverMessage(Self.serverMessage(from: data), status: status)
        }
        guard let decoded = try? decoder.decode(SessionResponse.self, from: data) else {
            throw APIError.decoding
        }
        return Session(token: decoded.token, account: decoded.account)
    }

    private func request(
        path: String, method: String, token: String?, body: [String: String]? = nil
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
        } catch {
            throw APIError.network
        }
    }
}
