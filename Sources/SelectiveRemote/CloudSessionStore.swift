import Foundation
import Security

protocol SelectiveRemoteCloudTokenStore: Sendable {
    func token(for endpoint: URL) throws -> String?
    func saveToken(_ token: String, for endpoint: URL) throws
    func removeToken(for endpoint: URL) throws
}

struct SelectiveRemoteCloudKeychainTokenStore: SelectiveRemoteCloudTokenStore {
    static let service = "local.selectiveremote.cloud.session.v1"

    func token(for endpoint: URL) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(for: endpoint),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { throw KeychainError.invalidData }
        return token
    }

    func saveToken(_ token: String, for endpoint: URL) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.invalidData }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(for: endpoint)
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func removeToken(for endpoint: URL) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(for: endpoint)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func account(for endpoint: URL) -> String {
        endpoint.absoluteString
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
