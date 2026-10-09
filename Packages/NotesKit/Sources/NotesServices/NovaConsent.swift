import Foundation
import Observation

/// Whether the signed-in account has agreed to NOVA sending what they ask
/// about to the AI provider.
///
/// Nothing reaches the provider without it: `NovaConversation` holds every
/// request at one gate until this says yes, and the user can take it back in
/// Settings. App Store Review Guideline 5.1.2(i) requires that permission
/// before personal data goes to a third-party AI, and note content never goes
/// to AI without consent.
///
/// It is kept per account, so a second person signing in on the same iPad is
/// asked for themselves, and per version of the disclosure: if what NOVA sends
/// or who it goes to changes, `currentVersion` goes up and everyone is asked
/// again.
@MainActor
@Observable
public final class NovaConsent {
    /// Bump when the disclosure changes in substance.
    public static let currentVersion = 1

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let account: @MainActor () -> String?
    /// Changes on every grant or revoke, so views reading `isGranted` update.
    private var revision = 0

    public init(defaults: UserDefaults = .standard, account: @escaping @MainActor () -> String?) {
        self.defaults = defaults
        self.account = account
    }

    public var isGranted: Bool {
        _ = revision
        return defaults.bool(forKey: key)
    }

    public func grant() {
        defaults.set(true, forKey: key)
        revision += 1
    }

    public func revoke() {
        defaults.removeObject(forKey: key)
        revision += 1
    }

    /// No account (a key entered by hand, no session) is still one person:
    /// the device's.
    private var key: String {
        "novaConsent.v\(Self.currentVersion).\(account() ?? "device")"
    }
}
