import Foundation
import Observation

/// The one source of truth for sign-in state. Holds the ClassMate session token
/// (Keychain) and the cached profile; the app gates the library behind
/// `state == .authenticated`.
///
/// Architected so server-side session validation can be strengthened later:
/// callers only ever read `state`/`user`, never the token itself.
@MainActor
@Observable
public final class AuthService {
    public enum State: Equatable, Sendable {
        case loading
        case signedOut
        case authenticated
    }

    public private(set) var state: State = .loading
    public private(set) var user: ClassMateUser?
    public private(set) var lastError: String?

    private let client: ClassMateAPIClient
    private let keychain: any SecretStore
    private let profileDefaultsKey = "cachedProfile.v1"

    public init(client: ClassMateAPIClient = ClassMateAPIClient(), keychain: any SecretStore = KeychainStore()) {
        self.client = client
        self.keychain = keychain
        if let data = UserDefaults.standard.data(forKey: profileDefaultsKey),
           let cached = try? JSONDecoder().decode(ClassMateUser.self, from: data) {
            user = cached
        }
    }

    public var token: String? { keychain.get(.authToken) }

    /// Called at launch: if we hold a token, confirm it against `/auth/me`.
    /// A cached profile means we can show the UI immediately and refresh async.
    public func restore() async {
        guard let token = keychain.get(.authToken) else {
            state = .signedOut
            return
        }
        if user != nil { state = .authenticated } // optimistic from cache
        do {
            let fresh = try await client.me(token: token)
            user = fresh
            cache(fresh)
            state = .authenticated
        } catch APIError.notAuthenticated {
            signOutLocally()
        } catch {
            // Network hiccup: keep the cached session usable offline.
            state = user != nil ? .authenticated : .signedOut
        }
    }

    public func signIn(identifier: String, password: String) async -> Bool {
        lastError = nil
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, !password.isEmpty else {
            lastError = "Enter your email/username and password."
            return false
        }
        do {
            let token = try await client.login(identifier: id, password: password)
            keychain.set(token, for: .authToken)
            let profile = try await client.me(token: token)
            user = profile
            cache(profile)
            state = .authenticated
            return true
        } catch APIError.invalidCredentials {
            lastError = "Incorrect email/username or password."
            return false
        } catch APIError.network {
            lastError = "Couldn't reach ClassMate. Check your connection."
            return false
        } catch {
            lastError = "Something went wrong signing in."
            return false
        }
    }

    public func register(email: String, name: String, password: String) async -> Bool {
        lastError = nil
        do {
            let token = try await client.register(
                email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                name: name.trimmingCharacters(in: .whitespaces),
                password: password,
                username: nil
            )
            keychain.set(token, for: .authToken)
            let profile = try? await client.me(token: token)
            user = profile
            if let profile { cache(profile) }
            state = .authenticated
            return true
        } catch APIError.badResponse(let status) where status == 409 {
            lastError = "That email is already registered. Try signing in."
            return false
        } catch {
            lastError = "Couldn't create your account. Try again."
            return false
        }
    }

    /// Sends a password-reset link via ClassMate's backend (email channel).
    public func requestPasswordReset(identifier: String) async -> Bool {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        return (try? await client.forgotPassword(identifier: id)) ?? false
    }

    public func signOut() {
        signOutLocally()
    }

    private func signOutLocally() {
        keychain.remove(.authToken)
        UserDefaults.standard.removeObject(forKey: profileDefaultsKey)
        user = nil
        state = .signedOut
    }

    private func cache(_ profile: ClassMateUser) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileDefaultsKey)
        }
    }
}
