import Foundation
import Security
import Darwin
import CryptoKit

struct CredentialVaultMigrationReport: Equatable, Sendable {
    var discovered = 0
    var imported = 0
    var alreadyStored = 0
    var failed = 0
}

/// Stores Selective Remote password secrets and device-bound Cloud state inside
/// one generic-password Keychain item. Ad-hoc signed builds get a new designated
/// identity after an update, so legacy per-profile Keychain ACLs can ask for
/// authorization once per item. A single vault reduces that to one Keychain
/// authorization. Cooperating writers read and update under the same process
/// lock; older versions do not honor it and still need storage isolation.
final class UnifiedCredentialVault: @unchecked Sendable {
    static let shared = UnifiedCredentialVault()
    static let service = "local.selectiveremote.credentials.unified.v2"
    private static let legacyUnifiedService = "local.selectiveremote.credentials.unified.v1"
    private static let migrationService = "local.selectiveremote.credentials.unified.v2-migration"
    static let account = "credential-vault"
    private static let protectedDataPrefix = "\u{1E}protected-data\u{1F}"

    private static let processLock = NSRecursiveLock()
    // Accessed only while processLock is held, including across nested operations.
    nonisolated(unsafe) private static var activeFileLock: (path: String, fd: Int32, depth: Int)?
    private let lock = UnifiedCredentialVault.processLock
    private var observedExistingItem = false
    private let defaults: UserDefaults
    private let lockDirectory: URL?
    private let indexKey = "SelectiveRemote.keychain.unifiedVault.index.v2"
    private let suppressedLegacyKey = "SelectiveRemote.keychain.unifiedVault.suppressedLegacy.v1"

    init(defaults: UserDefaults = .standard, lockDirectory: URL? = nil) {
        self.defaults = defaults
        self.lockDirectory = lockDirectory
    }

    private func acquireInterprocessLock() throws -> Int32 {
        let directory: URL
        if let lockDirectory {
            directory = lockDirectory
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else { throw KeychainError.vaultLockUnavailable }
            directory = applicationSupport.appendingPathComponent("Selective Remote", isDirectory: true)
                .appendingPathComponent("CredentialLocks", isDirectory: true)
        }
        // Keep the lexical URL stable while a directory is first created;
        // filesystem-dependent canonicalization can change on nested calls.
        let lockPath = directory.path
        if let active = Self.activeFileLock {
            guard active.path == lockPath else { throw KeychainError.vaultLockUnavailable }
            Self.activeFileLock = (active.path, active.fd, active.depth + 1)
            return active.fd
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw KeychainError.vaultLockUnavailable }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw KeychainError.vaultLockUnavailable }
        defer { Darwin.close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(), (directoryInfo.st_mode & 0o077) == 0
        else { throw KeychainError.vaultLockUnavailable }
        // Concurrent first creation on macOS can transiently return ENOENT.
        // Retry only that condition and still validate the opened inode below.
        var descriptor: Int32 = -1
        for attempt in 0..<4 {
            descriptor = openat(directoryFD, "unified-credentials.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if descriptor >= 0 || errno != ENOENT { break }
            if attempt < 3 { usleep(1_000) }
        }
        guard descriptor >= 0 else { throw KeychainError.vaultLockUnavailable }
        var info = stat(), pathInfo = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0, info.st_nlink == 1,
              fstatat(directoryFD, "unified-credentials.lock", &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              pathInfo.st_ino == info.st_ino, pathInfo.st_dev == info.st_dev
        else { Darwin.close(descriptor); throw KeychainError.vaultLockUnavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN { throw KeychainError.concurrentVaultWrite }
            throw KeychainError.vaultLockUnavailable
        }
        Self.activeFileLock = (lockPath, descriptor, 1)
        return descriptor
    }

    private func releaseInterprocessLock(_ descriptor: Int32) {
        guard let active = Self.activeFileLock, active.fd == descriptor else { preconditionFailure("Unbalanced vault lock") }
        if active.depth > 1 {
            Self.activeFileLock = (active.path, active.fd, active.depth - 1)
            return
        }
        Self.activeFileLock = nil
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        return try body()
    }

    static func entryKey(for reference: KeychainCredentialReference) -> String {
        reference.service + "\u{1F}" + reference.account
    }

    static func protectedDataKey(namespace: String, key: String) -> String {
        protectedDataPrefix + namespace + "\u{1F}" + key
    }

    private static func isProtectedDataKey(_ key: String) -> Bool {
        key.hasPrefix(protectedDataPrefix)
    }

    private static func suppressionKey(_ key: String) -> String {
        protectedDataKey(namespace: "legacy-credential-tombstone.v1", key: key)
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index.count
    }

    func contains(reference: KeychainCredentialReference) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        let key = Self.entryKey(for: reference)
        return try loadCurrent()[key] != nil
    }

    func isLegacySuppressed(reference: KeychainCredentialReference) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        return try loadCurrent()[Self.suppressionKey(Self.entryKey(for: reference))] != nil
    }

    func read(reference: KeychainCredentialReference) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        let secrets = try loadCurrent()
        return secrets[Self.entryKey(for: reference)]
    }

    func save(_ secret: String, reference: KeychainCredentialReference) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        var secrets = try loadCurrent()
        let key = Self.entryKey(for: reference)
        secrets[key] = secret
        secrets.removeValue(forKey: Self.suppressionKey(key))
        try persist(secrets)
        var updatedIndex = index
        updatedIndex.insert(key)
        index = updatedIndex
    }

    func save(_ entries: [(reference: KeychainCredentialReference, secret: String)]) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        var secrets = try loadCurrent()
        var updatedIndex = index
        for entry in entries {
            let key = Self.entryKey(for: entry.reference)
            secrets[key] = entry.secret
            updatedIndex.insert(key)
            secrets.removeValue(forKey: Self.suppressionKey(key))
        }
        try persist(secrets)
        index = updatedIndex
    }

    func delete(reference: KeychainCredentialReference) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        let key = Self.entryKey(for: reference)
        var secrets = try loadCurrent()
        secrets.removeValue(forKey: key)
        secrets[Self.suppressionKey(key)] = "1"
        try persist(secrets)
        var updatedIndex = index
        updatedIndex.remove(key)
        index = updatedIndex
    }

    /// Stores device-bound binary state in the same Keychain item as connection
    /// credentials. Namespaces keep Cloud state separate without creating a
    /// second Keychain ACL (and therefore a second authorization prompt).
    func readProtectedData(namespace: String, key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        guard let encoded = try loadCurrent()[Self.protectedDataKey(namespace: namespace, key: key)] else {
            return nil
        }
        guard let data = Data(base64Encoded: encoded) else { throw KeychainError.invalidData }
        return data
    }

    func saveProtectedData(_ data: Data, namespace: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        var secrets = try loadCurrent()
        secrets[Self.protectedDataKey(namespace: namespace, key: key)] = data.base64EncodedString()
        try persist(secrets)
    }

    func deleteProtectedData(namespace: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        var secrets = try loadCurrent()
        if secrets.removeValue(forKey: Self.protectedDataKey(namespace: namespace, key: key)) != nil {
            try persist(secrets)
        }
    }

    func unlock() throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        _ = try loadCurrent()
    }

    func exportedSecrets() throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        return try loadCurrent().filter { !Self.isProtectedDataKey($0.key) }
    }

    func replaceSecrets(_ secrets: [String: String]) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        let current = try loadCurrent()
        var protectedData = current.filter { Self.isProtectedDataKey($0.key) }
        for key in current.keys where !Self.isProtectedDataKey(key) && secrets[key] == nil {
            protectedData[Self.suppressionKey(key)] = "1"
        }
        for key in secrets.keys { protectedData.removeValue(forKey: Self.suppressionKey(key)) }
        let merged = secrets.merging(protectedData) { _, protectedValue in protectedValue }
        try persist(merged)
        index = Set(secrets.keys)
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
        let fileLock = try acquireInterprocessLock()
        defer { releaseInterprocessLock(fileLock) }
        var secrets = try loadCurrent()
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
                if secrets[key] != nil || secrets[Self.suppressionKey(key)] != nil {
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
            index = Set(secrets.keys.filter { !Self.isProtectedDataKey($0) })
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
    }

    private func loadCurrent() throws -> [String: String] {
        let data = try loadVersionedItem()
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { throw KeychainError.invalidData }
        observedExistingItem = true
        index = Set(decoded.keys.filter { !Self.isProtectedDataKey($0) })
        return decoded
    }

    // The checkpoint lives in a distinct Keychain item, not in defaults. It is
    // committed before the new vault is returned to a caller, so losing the new
    // item later cannot silently reimport a retired session from the source.
    // All callers hold the cooperating-process lock throughout this procedure.
    private func loadVersionedItem() throws -> Data {
        let markerData = try readItem(service: Self.migrationService)
        let current = try readItem(service: Self.service)
        if let markerData {
            guard let marker = String(data: markerData, encoding: .utf8) else { throw KeychainError.invalidData }
            if marker == "committed" {
                guard let current else { throw KeychainError.unifiedVaultDisappeared }
                return current
            }
            guard marker.hasPrefix("pending:"), marker.count == 72 else { throw KeychainError.invalidData }
            let expected = String(marker.dropFirst(8))
            let candidate: Data
            if let current { candidate = current }
            else { candidate = try legacySnapshot() }
            guard Self.digest(candidate) == expected,
                  (try? JSONDecoder().decode([String: String].self, from: candidate)) != nil
            else { throw KeychainError.invalidData }
            if current == nil { try addItem(candidate, service: Self.service) }
            guard try readItem(service: Self.service) == candidate else { throw KeychainError.invalidData }
            try updateItem(Data("committed".utf8), service: Self.migrationService)
            return candidate
        }
        guard current == nil, !observedExistingItem else { throw KeychainError.unifiedVaultDisappeared }
        let snapshot = try legacySnapshot()
        let marker = Data(("pending:" + Self.digest(snapshot)).utf8)
        try addItem(marker, service: Self.migrationService)
        try addItem(snapshot, service: Self.service)
        guard try readItem(service: Self.service) == snapshot else { throw KeychainError.invalidData }
        try updateItem(Data("committed".utf8), service: Self.migrationService)
        return snapshot
    }

    private func legacySnapshot() throws -> Data {
        let data = try readItem(service: Self.legacyUnifiedService) ?? Data("{}".utf8)
        guard var entries = try? JSONDecoder().decode([String: String].self, from: data) else { throw KeychainError.invalidData }
        let suppressed = suppressedLegacy
        guard !suppressed.isEmpty else { return data }
        for key in suppressed {
            guard entries[key] == nil else { throw KeychainError.invalidData }
            entries[Self.suppressionKey(key)] = "1"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(entries)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func itemQuery(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: Self.account]
    }

    private func readItem(service: String) throws -> Data? {
        var query = itemQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return data
    }

    private func addItem(_ data: Data, service: String) throws {
        var item = itemQuery(service: service)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private func updateItem(_ data: Data, service: String) throws {
        let status = SecItemUpdate(itemQuery(service: service) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
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
        if updateStatus == errSecSuccess {
            observedExistingItem = true
            // Accessibility hardening is best-effort for an existing legacy
            // item: failure must never discard a successfully stored session.
            _ = SecItemUpdate(
                key as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
                    as CFDictionary
            )
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        guard !observedExistingItem else { throw KeychainError.unifiedVaultDisappeared }
        var item = key
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
        observedExistingItem = true
    }
}
