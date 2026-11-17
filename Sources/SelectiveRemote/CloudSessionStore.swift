import Foundation
import Security

protocol SelectiveRemoteCloudTokenStore: Sendable {
    func token(for endpoint: URL) throws -> String?
    func saveToken(_ token: String, for endpoint: URL) throws
    func removeToken(for endpoint: URL) throws
    func publicationAccountBinding(key: String) throws -> Data?
    func savePublicationAccountBinding(_ data: Data, key: String) throws
}

extension SelectiveRemoteCloudTokenStore {
    func publicationAccountBinding(key: String) throws -> Data? { nil }
    func savePublicationAccountBinding(_ data: Data, key: String) throws {}
}

struct SelectiveRemoteCloudKeychainTokenStore: SelectiveRemoteCloudTokenStore {
    static let legacyService = "local.selectiveremote.cloud.session.v1"
    static let service = legacyService
    private let envelopeStore: SelectiveRemoteCloudSecureEnvelopeStore
    private let legacyReader: (@Sendable (URL) throws -> String?)?
    private let legacyRemover: (@Sendable (URL) throws -> Void)?

    init() {
        envelopeStore = .init()
        legacyReader = nil
        legacyRemover = nil
    }

    init(
        envelopeStore: SelectiveRemoteCloudSecureEnvelopeStore,
        legacyReader: @escaping @Sendable (URL) throws -> String?,
        legacyRemover: @escaping @Sendable (URL) throws -> Void
    ) {
        self.envelopeStore = envelopeStore
        self.legacyReader = legacyReader
        self.legacyRemover = legacyRemover
    }
    func publicationAccountBinding(key: String) throws -> Data? { try UnifiedCredentialVault.shared.readProtectedData(namespace: "publication-session-account.v1", key: key) }
    func savePublicationAccountBinding(_ data: Data, key: String) throws { try UnifiedCredentialVault.shared.saveProtectedData(data, namespace: "publication-session-account.v1", key: key) }

    func token(for endpoint: URL) throws -> String? {
        let existing = try envelopeStore.envelope(for: endpoint)
        if let token = existing?.sessionToken {
            return token
        }
        if existing?.legacySessionRetired == true { return nil }
        var selected: String?
        var migrated = false
        try envelopeStore.update(for: endpoint) { envelope in
            if let current = envelope.sessionToken {
                selected = current
            } else if !envelope.legacySessionRetired, let legacy = try legacyToken(for: endpoint) {
                envelope.sessionToken = legacy
                selected = legacy
                migrated = true
            }
        }
        if migrated { try? removeLegacyToken(for: endpoint) }
        return selected
    }

    func saveToken(_ token: String, for endpoint: URL) throws {
        guard !token.isEmpty else { throw KeychainError.invalidData }
        try envelopeStore.update(for: endpoint) {
            $0.sessionToken = token
        }
    }

    func removeToken(for endpoint: URL) throws {
        try envelopeStore.update(for: endpoint) {
            $0.sessionToken = nil
            $0.legacySessionRetired = true
        }
        // The tombstone protects current versions; old versions do not know
        // it, so a legacy deletion failure must still be reported to the user.
        try removeLegacyToken(for: endpoint)
    }

    private func legacyToken(for endpoint: URL) throws -> String? {
        if let legacyReader { return try legacyReader(endpoint) }
        var query = legacyQuery(for: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { throw KeychainError.invalidData }
        return token
    }

    private func removeLegacyToken(for endpoint: URL) throws {
        if let legacyRemover { return try legacyRemover(endpoint) }
        let status = SecItemDelete(legacyQuery(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func legacyQuery(for endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyService,
            kSecAttrAccount as String: endpoint.absoluteString
        ]
    }
}

final class SelectiveRemoteCloudMemoryTokenStore: SelectiveRemoteCloudTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    private var accountBindings: [String: Data] = [:]
    func publicationAccountBinding(key: String) -> Data? { lock.withLock { accountBindings[key] } }
    func savePublicationAccountBinding(_ data: Data, key: String) { lock.withLock { accountBindings[key] = data } }

    func token(for endpoint: URL) -> String? {
        lock.withLock { tokens[endpoint.absoluteString] }
    }

    func saveToken(_ token: String, for endpoint: URL) {
        lock.withLock { tokens[endpoint.absoluteString] = token }
    }

    func removeToken(for endpoint: URL) {
        _ = lock.withLock { tokens.removeValue(forKey: endpoint.absoluteString) }
    }
}
