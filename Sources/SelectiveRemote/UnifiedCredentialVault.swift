import Foundation
import Security

struct CredentialVaultMigrationReport: Equatable, Sendable {
    var discovered = 0
    var imported = 0
    var alreadyStored = 0
    var failed = 0
}

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

    /// One-time migration for existing per-profile Keychain records.
    ///
    /// Security.framework does not allow `kSecReturnData` together with
    /// `kSecMatchLimitAll` for password items. We therefore enumerate only
    /// non-secret attributes first and then read each password individually.
    /// Old ad-hoc ACLs may still require a one-time macOS authorization per
    /// legacy item; once imported, future app builds use the single vault item.
    @discardableResult
    func importLegacyItems(services: [String]) throws -> CredentialVaultMigrationReport {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try loadIfNeeded()
        var report = CredentialVaultMigrationReport()

        for service in Array(Set(services)).sorted() where service != Self.service {
            let accounts = try legacyAccounts(service: service)
            for account in accounts where !account.hasSuffix(".ssh-key-authorization") {
                report.discovered += 1
                let reference = KeychainCredentialReference(
                    service: service,
                    account: account
                )
                let key = Self.entryKey(for: reference)
                if secrets[key] != nil {
                    report.alreadyStored += 1
                    continue
                }

                let read = readLegacySecret(service: service, account: account)
                if read.status == errSecSuccess {
                    guard let secret = read.value, !secret.isEmpty else { continue }
                    secrets[key] = secret
                    report.imported += 1
                } else if read.status != errSecItemNotFound {
                    // Do not abort the entire migration because one old ACL is
                    // inaccessible or the user cancelled one authorization.
                    report.failed += 1
                }
            }
        }

        if report.imported > 0 {
            try persist(secrets)
            cachedSecrets = secrets
            index = Set(secrets.keys)
        }
        return report
    }

    private func legacyAccounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let item = result as? [String: Any] {
            items = [item]
        } else {
            return []
        }
        return Array(Set(items.compactMap { $0[kSecAttrAccount as String] as? String })).sorted()
    }

    private func readLegacySecret(service: String, account: String) -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (nil, status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return (nil, errSecDecode) }
        return (value, errSecSuccess)
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
