import Foundation

/// The ClassMate backend contract this app depends on. Base URL and routes are
/// the same server that powers the ClassMate app (extracted from its client),
/// so Notes signs in with the SAME accounts.
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
}

/// The `/auth/me` shape from ClassMate, trimmed to the fields Notes shows.
public struct ClassMateUser: Codable, Sendable, Equatable {
    public var id: String?
    public var email: String?
    public var username: String?
    public var roles: [String]
    public var schoolName: String?
    public var cohortName: String?
    public var grade: Int?
    public var fullName: String?
    public var displayName: String?
    public var phone: String?

    public init(
        id: String? = nil,
        email: String? = nil,
        username: String? = nil,
        roles: [String] = [],
        schoolName: String? = nil,
        cohortName: String? = nil,
        grade: Int? = nil,
        fullName: String? = nil,
        displayName: String? = nil,
        phone: String? = nil
    ) {
        self.id = id
        self.email = email
        self.username = username
        self.roles = roles
        self.schoolName = schoolName
        self.cohortName = cohortName
        self.grade = grade
        self.fullName = fullName
        self.displayName = displayName
        self.phone = phone
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, username, roles, schoolName, cohortName, grade, fullName, displayName, phone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        schoolName = try c.decodeIfPresent(String.self, forKey: .schoolName)
        cohortName = try c.decodeIfPresent(String.self, forKey: .cohortName)
        grade = try c.decodeIfPresent(Int.self, forKey: .grade)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
    }

    /// Best label for the user in UI.
    public var bestName: String {
        displayName ?? fullName ?? username ?? email ?? "Student"
    }

    public var initials: String {
        let source = bestName
        let parts = source.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased().isEmpty ? "?" : letters.joined().uppercased()
    }

    public var primaryRole: String? {
        let priority = ["MANAGER", "TEACHER", "ADMIN", "SECRETARY", "PARENT", "STUDENT"]
        return priority.first { roles.contains($0) }
    }
}

/// Minimal async HTTP client for the ClassMate auth surface. Injectable
/// `URLSession` keeps it unit-testable with a stub protocol handler.
public struct ClassMateAPIClient: Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = ClassMateAPI.baseURL()) {
        self.session = session
        self.baseURL = baseURL
    }

    /// `POST /auth/login` body `{identifier, password}` → `{token}`.
    public func login(identifier: String, password: String) async throws -> String {
        let body = ["identifier": identifier, "password": password]
        let (data, status) = try await post(path: "/auth/login", body: body, token: nil)
        if status == 401 { throw APIError.invalidCredentials }
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
        return try token(from: data)
    }

    /// `POST /auth/register` body `{email, name, password, username?}` → `{token}`.
    public func register(email: String, name: String, password: String, username: String?) async throws -> String {
        var body = ["email": email, "name": name, "password": password]
        if let username, !username.isEmpty { body["username"] = username }
        let (data, status) = try await post(path: "/auth/register", body: body, token: nil)
        if status == 409 { throw APIError.badResponse(status: 409) }
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
        return try token(from: data)
    }

    /// `POST /auth/forgot-password` body `{identifier, channel}` → `{sent}`.
    public func forgotPassword(identifier: String, channel: String = "email") async throws -> Bool {
        let body = ["identifier": identifier, "channel": channel]
        let (data, status) = try await post(path: "/auth/forgot-password", body: body, token: nil)
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
        struct SentResponse: Decodable { let sent: Bool? }
        let decoded = try? JSONDecoder().decode(SentResponse.self, from: data)
        return decoded?.sent ?? true
    }

    /// `GET /auth/me` (Bearer) → profile.
    public func me(token: String) async throws -> ClassMateUser {
        let (data, status) = try await get(path: "/auth/me", token: token)
        if status == 401 { throw APIError.notAuthenticated }
        guard (200..<300).contains(status) else { throw APIError.badResponse(status: status) }
        do {
            return try JSONDecoder().decode(ClassMateUser.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    // MARK: - Plumbing

    private func token(from data: Data) throws -> String {
        struct TokenResponse: Decodable { let token: String }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data).token
        } catch {
            throw APIError.decoding
        }
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

    private func post(path: String, body: [String: String], token: String?) async throws -> (Data, Int) {
        var req = request(path: path, method: "POST", token: token)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func get(path: String, token: String?) async throws -> (Data, Int) {
        try await send(request(path: path, method: "GET", token: token))
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
