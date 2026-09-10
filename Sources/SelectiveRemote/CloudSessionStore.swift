import Foundation
import Security

protocol SelectiveRemoteCloudTokenStore: Sendable {
    func token(for endpoint: URL) throws -> String?
    func saveToken(_ token: String, for endpoint: URL) throws
    func removeToken(for endpoint: URL) throws
}

struct SelectiveRemoteCloudKeychainTokenStore: SelectiveRemoteCloudTokenStore {
    static let legacyService = "local.selectiveremote.cloud.session.v1"
    static let service = legacyService
    private let envelopeStore = SelectiveRemoteCloudSecureEnvelopeStore()

    func token(for endpoint: URL) throws -> String? {
        if let token = try envelopeStore.envelope(for: endpoint)?.sessionToken {
            return token
        }
        guard let legacy = try legacyToken(for: endpoint) else { return nil }
        try saveToken(legacy, for: endpoint)
        try? removeLegacyToken(for: endpoint)
        return legacy
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
        }
        try? removeLegacyToken(for: endpoint)
    }

    private func legacyToken(for endpoint: URL) throws -> String? {
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

    func token(for endpoint: URL) -> String? {
        lock.withLock { tokens[endpoint.absoluteString] }
    }

    func saveToken(_ token: String, for endpoint: URL) {
        lock.withLock { tokens[endpoint.absoluteString] = token }
    }

    func removeToken(for endpoint: URL) {
        lock.withLock { tokens.removeValue(forKey: endpoint.absoluteString) }
    }
}
