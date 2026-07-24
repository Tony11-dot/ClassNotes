import Foundation
import Security

/// The secrets the app holds: the ClassMate session token and the Groq API key.
public enum SecretKey: String, Sendable {
    case authToken = "com.classmate.notes.authToken"
    case groqAPIKey = "com.classmate.notes.groqAPIKey"
}

/// Abstraction over secret storage so services can be unit-tested without the
/// Keychain (which is unavailable in SPM test hosts). Production uses
/// `KeychainStore`; tests use `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    func get(_ key: SecretKey) -> String?
    func set(_ value: String?, for key: SecretKey)
    func remove(_ key: SecretKey)
}

/// iOS Keychain-backed secret storage. Never store credentials in UserDefaults.
public struct KeychainStore: SecretStore {
    private let service: String

    public init(service: String = "com.classmate.notes") {
        self.service = service
    }

    public func set(_ value: String?, for key: SecretKey) {
        guard let value, !value.isEmpty else {
            remove(key)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    public func get(_ key: SecretKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    public func remove(_ key: SecretKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory secret store for tests (and a safe fallback). Thread-safe.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [SecretKey: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func get(_ key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ value: String?, for key: SecretKey) {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty { storage[key] = value } else { storage[key] = nil }
    }

    public func remove(_ key: SecretKey) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}
