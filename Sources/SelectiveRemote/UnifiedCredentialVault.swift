import Foundation
import Security

/// Stores all Selective Remote password secrets inside one generic-password
/// Keychain item. Ad-hoc signed builds get a new designated identity after an
/// update, so legacy per-profile Keychain ACLs can ask for authorization once
/// per item. A single vault reduces that to one Keychain authorization and the
/// decoded vault is cached only in process memory for the lifetime of the app.
final class UnifiedCredentialVault: @unchecked Sendable {
    static let shared = UnifiedCredentialVault()
    static let service = "local.selectiveremote.credentials.unified.v1"
    static let account = "credential-vault"

    private let lock = NSRecursiveLock()
    private var cachedSecrets: [String: String]?
    private let defaults: UserDefaults
    private let indexKey = "SelectiveRemote.keychain.unifiedVault.index.v1"
    private let suppressedLegacyKey = "SelectiveRemote.keychain.unifiedVault.suppressedLegacy.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func entryKey(for reference: KeychainCredentialReference) -> String {
        reference.service + "\u{1F}" + reference.account
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index.count
    }

    func contains(reference: KeychainCredentialReference) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.entryKey(for: reference)
        if let cachedSecrets { return cachedSecrets[key] != nil }
        return index.contains(key)
    }

    func isLegacySuppressed(reference: KeychainCredentialReference) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressedLegacy.contains(Self.entryKey(for: reference))
    }

    func read(reference: KeychainCredentialReference) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let secrets = try loadIfNeeded()
        return secrets[Self.entryKey(for: reference)]
    }

    func save(_ secret: String, reference: KeychainCredentialReference) throws {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try loadIfNeeded()
        let key = Self.entryKey(for: reference)
        secrets[key] = secret
        try persist(secrets)
        cachedSecrets = secrets
        var updatedIndex = index
        updatedIndex.insert(key)
        index = updatedIndex
        var suppressed = suppressedLegacy
        suppressed.remove(key)
        suppressedLegacy = suppressed
    }

    func delete(reference: KeychainCredentialReference) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.entryKey(for: reference)
        var secrets = try loadIfNeeded()
        if secrets.removeValue(forKey: key) != nil {
            try persist(secrets)
            cachedSecrets = secrets
        }
        var updatedIndex = index
        updatedIndex.remove(key)
        index = updatedIndex
        var suppressed = suppressedLegacy
        suppressed.insert(key)
        suppressedLegacy = suppressed
    }

    func unlock() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try loadIfNeeded()
    }

    /// One-time migration for existing per-profile Keychain records. The query
    /// is performed per Selective Remote service with MatchLimitAll, so macOS
    /// can authorize the batch instead of the app issuing 100 independent reads.
    @discardableResult
    func importLegacyItems(services: [String]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try loadIfNeeded()
        var imported = 0

        for service in Array(Set(services)).sorted() where service != Self.service {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else {
                throw KeychainError.unexpectedStatus(status)
            }

            let items: [[String: Any]]
            if let array = result as? [[String: Any]] {
                items = array
            } else if let item = result as? [String: Any] {
                items = [item]
            } else {
                continue
            }

            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let secret = String(data: data, encoding: .utf8),
                      !secret.isEmpty
                else { continue }
                let reference = KeychainCredentialReference(
                    service: service,
                    account: account
                )
                let key = Self.entryKey(for: reference)
                if secrets[key] != secret {
                    secrets[key] = secret
                    imported += 1
                }
            }
        }

        if imported > 0 {
            try persist(secrets)
            cachedSecrets = secrets
            index = Set(secrets.keys)
        }
        return imported
    }

    private var index: Set<String> {
        get { Set(defaults.stringArray(forKey: indexKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: indexKey) }
    }

    private var suppressedLegacy: Set<String> {
        get { Set(defaults.stringArray(forKey: suppressedLegacyKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: suppressedLegacyKey) }
    }

    private func loadIfNeeded() throws -> [String: String] {
        if let cachedSecrets { return cachedSecrets }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            cachedSecrets = [:]
            return [:]
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            throw KeychainError.invalidData
        }
        cachedSecrets = decoded
        index = Set(decoded.keys)
        return decoded
    }

    private func persist(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let updateStatus = SecItemUpdate(
            key as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var item = key
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }
}
