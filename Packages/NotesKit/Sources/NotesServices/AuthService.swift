import Foundation
import Observation

/// The one source of truth for sign-in state. Holds the ClassNotes session token
/// (Keychain) and the cached account.
///
/// The library does NOT need an account (`libraryIsOpen`, D-001): an account
/// adds the ClassMate mirror, NOVA and settings sync, and nothing else. A
/// device that chose to work without one, or whose session the server stopped
/// honouring, keeps its notebooks. Locking a student out of their own lecture
/// notes because a token expired was the failure this exists to prevent.
///
/// These are ClassNotes' OWN accounts (`/classnotes/auth/*`), not ClassMate
/// school accounts. The app used to sign in with the latter purely because that
/// backend already authenticated the library sync — which meant a student who
/// only wanted a notebook had to be enrolled in a school platform to open one.
/// The token this holds is accepted by every `/classnotes/*` endpoint the app
/// already used, NOVA included, so nothing downstream had to change.
///
/// Architected so server-side session validation can be strengthened later:
/// callers only ever read `state`/`account`, never the token itself.
@MainActor
@Observable
public final class AuthService {
    public enum State: Equatable, Sendable {
        case loading
        case signedOut
        case authenticated
    }

    public private(set) var state: State = .loading
    public private(set) var account: ClassNotesAccount?
    public private(set) var lastError: String?
    /// The device uses ClassNotes without an account. Set by "Continue
    /// without an account", and by any sign-out the user didn't ask for (a
    /// rejected session, a deleted account), so the notebooks stay reachable.
    public private(set) var worksWithoutAccount: Bool
    /// Said once when the device was signed out without asking: what
    /// happened, that the notebooks are safe, and what signing in brings back.
    public var signedOutNotice: LibraryNotice?
    /// Runs after every successful sign-in or sign-up, so the account's
    /// library and settings sync without waiting for the next launch.
    @ObservationIgnored public var onSignIn: (@MainActor () -> Void)?

    /// Whether the library is shown: signed in, or working without an account.
    public var libraryIsOpen: Bool {
        state == .authenticated || (state == .signedOut && worksWithoutAccount)
    }

    private let client: ClassNotesAuthClient
    private let keychain: any SecretStore
    private let defaults: UserDefaults
    private static let worksWithoutAccountKey = "worksWithoutAccount.v1"
    /// v2 because v1 cached a `ClassMateUser`. A stale v1 blob is simply left
    /// behind rather than migrated: it described a different account space, and
    /// decoding it into a ClassNotes account would invent an id that names
    /// nothing on the server.
    private let profileDefaultsKey = "cachedClassNotesAccount.v2"
    private let legacyProfileDefaultsKey = "cachedProfile.v1"

    public init(
        client: ClassNotesAuthClient = ClassNotesAuthClient(),
        keychain: any SecretStore = KeychainStore(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.keychain = keychain
        self.defaults = defaults
        worksWithoutAccount = defaults.bool(forKey: Self.worksWithoutAccountKey)
        if let data = defaults.data(forKey: profileDefaultsKey),
           let cached = try? JSONDecoder().decode(ClassNotesAccount.self, from: data) {
            account = cached
        }
    }

    public var token: String? { keychain.get(.authToken) }

    /// Called at launch: if we hold a token, confirm it against
    /// `/classnotes/auth/me`. A cached account means the UI can come up
    /// immediately and refresh behind it.
    public func restore() async {
        guard let token = keychain.get(.authToken) else {
            state = .signedOut
            return
        }
        if account != nil { state = .authenticated } // optimistic from cache
        do {
            let fresh = try await client.me(token: token)
            account = fresh
            cache(fresh)
            state = .authenticated
        } catch APIError.notAuthenticated {
            // The token is for an account that is gone, or predates a password
            // change. Either way it will never work again — but the notebooks
            // on this device are still the user's, so the library stays open.
            signOutLocally(keepingLibrary: .sessionEnded)
        } catch {
            // A network hiccup is NOT a signed-out state: the notebooks are on
            // disk and the editor works offline, so a cached session stays
            // usable and simply revalidates on the next launch. Without a cached
            // account there is nothing to show, so fall back to signed out.
            state = account == nil ? .signedOut : .authenticated
        }
    }

    public func signIn(email: String, password: String) async -> Bool {
        lastError = nil
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty, !password.isEmpty else {
            lastError = "Enter your email and password."
            return false
        }
        do {
            let session = try await client.login(email: address, password: password)
            adopt(session)
            return true
        } catch APIError.invalidCredentials {
            lastError = "Incorrect email or password."
            return false
        } catch APIError.network {
            lastError = "Couldn't reach ClassNotes. Check your connection."
            return false
        } catch APIError.server(let message, _) {
            lastError = message
            return false
        } catch {
            lastError = "Couldn't sign in right now. Try again in a moment."
            return false
        }
    }

    public func register(email: String, name: String, password: String) async -> Bool {
        lastError = nil
        do {
            let session = try await client.register(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                password: password,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            adopt(session)
            return true
        } catch APIError.server(let message, _) {
            // The server's own words: the address is taken, or the password is
            // too short. Both tell the user exactly what to change.
            lastError = message
            return false
        } catch APIError.network {
            lastError = "Couldn't reach ClassNotes. Check your connection."
            return false
        } catch APIError.badResponse(let status) where status == 409 {
            lastError = "That email already has a ClassNotes account. Try signing in."
            return false
        } catch {
            lastError = "Couldn't create your account. Try again."
            return false
        }
    }

    /// Renames the account. Succeeds locally only if the server took it, so the
    /// profile screen can't show a name the next launch would contradict.
    public func updateName(_ name: String) async -> Bool {
        lastError = nil
        guard let token = keychain.get(.authToken) else { return false }
        do {
            let updated = try await client.updateName(
                name.trimmingCharacters(in: .whitespacesAndNewlines), token: token
            )
            account = updated
            cache(updated)
            return true
        } catch APIError.server(let message, _) {
            lastError = message
            return false
        } catch {
            lastError = "Couldn't save your name. Try again."
            return false
        }
    }

    /// Changes the password and KEEPS this device signed in. The server revokes
    /// every token issued before the change — including the one in the Keychain
    /// right now — and returns a replacement, so storing it is not an
    /// optimisation but the difference between staying signed in and being
    /// kicked out on the next request.
    public func changePassword(current: String, new: String) async -> Bool {
        lastError = nil
        guard let token = keychain.get(.authToken) else { return false }
        do {
            let replacement = try await client.changePassword(
                current: current, new: new, token: token
            )
            keychain.set(replacement, for: .authToken)
            return true
        } catch APIError.invalidCredentials {
            lastError = "That is not your current password."
            return false
        } catch APIError.server(let message, _) {
            lastError = message
            return false
        } catch {
            lastError = "Couldn't change your password. Try again."
            return false
        }
    }

    /// Deletes the account on the server, then signs out locally.
    ///
    /// Required by App Store guideline 5.1.1(v) — an app that creates accounts
    /// has to be able to delete them from inside the app. The server drops every
    /// notebook the account owned; the local documents are deliberately left
    /// alone, because they are the user's own files and destroying them is not
    /// what "delete my account" asked for.
    public func deleteAccount(password: String) async -> Bool {
        lastError = nil
        guard let token = keychain.get(.authToken) else { return false }
        do {
            try await client.deleteAccount(password: password, token: token)
            signOutLocally(keepingLibrary: .accountDeleted)
            return true
        } catch APIError.invalidCredentials {
            lastError = "Incorrect password."
            return false
        } catch APIError.network {
            lastError = "Couldn't reach ClassNotes. Check your connection."
            return false
        } catch {
            lastError = "Couldn't delete your account. Try again."
            return false
        }
    }

    /// Asks for a password-reset link. The server answers identically whether or
    /// not the address has an account, so this never reports "no such account".
    public func requestPasswordReset(email: String) async -> PasswordResetResult {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return .init(sent: false, message: "Enter your email.")
        }
        return (try? await client.forgotPassword(email: address))
            ?? .init(sent: false, message: "Couldn't send the reset link. Check your connection and try again.")
    }

    /// Signing out on purpose shows the sign-in screen, which offers to carry
    /// on without an account.
    public func signOut() {
        signOutLocally(keepingLibrary: nil)
    }

    /// Opens the library with no account. The notebooks live on the device;
    /// signing in later adds sync and NOVA without changing them.
    public func continueWithoutAccount() {
        lastError = nil
        setWorksWithoutAccount(true)
    }

    private func adopt(_ session: ClassNotesAuthClient.Session) {
        keychain.set(session.token, for: .authToken)
        account = session.account
        cache(session.account)
        signedOutNotice = nil
        state = .authenticated
        onSignIn?()
    }

    /// Why the device was signed out without asking.
    enum UnaskedSignOut {
        case sessionEnded, accountDeleted
    }

    /// `keepingLibrary`: the sign-out wasn't the user's choice, so the
    /// library stays open and they are told why.
    private func signOutLocally(keepingLibrary reason: UnaskedSignOut?) {
        keychain.remove(.authToken)
        defaults.removeObject(forKey: profileDefaultsKey)
        defaults.removeObject(forKey: legacyProfileDefaultsKey)
        account = nil
        switch reason {
        case .sessionEnded:
            setWorksWithoutAccount(true)
            signedOutNotice = LibraryNotice(
                title: "You've been signed out",
                message: "Your notebooks are still here on this device. Sign in again in "
                    + "Settings to sync them and use NOVA."
            )
        case .accountDeleted:
            setWorksWithoutAccount(true)
        case nil:
            setWorksWithoutAccount(false)
        }
        state = .signedOut
    }

    private func setWorksWithoutAccount(_ value: Bool) {
        worksWithoutAccount = value
        defaults.set(value, forKey: Self.worksWithoutAccountKey)
    }

    private func cache(_ profile: ClassNotesAccount) {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: profileDefaultsKey)
        }
    }
}
