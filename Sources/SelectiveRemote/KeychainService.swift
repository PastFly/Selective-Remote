import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String }
                ?? "неизвестная ошибка"
            return "Ошибка Keychain: \(message) (\(status))"
        case .invalidData:
            return "Keychain вернул некорректные данные"
        }
    }
}

enum KeychainCredentialKind: String {
    case rdp
    case gateway
    case ssh
    case forwarding

    func account(profileID: UUID) -> String {
        switch self {
        case .rdp:
            // Keep the legacy account name so existing saved RDP passwords
            // continue to work after upgrading from SelectiveRemote 0.4.x.
            profileID.uuidString
        case .gateway:
            "\(profileID.uuidString).gateway"
        case .ssh:
            "\(profileID.uuidString).ssh"
        case .forwarding:
            "\(profileID.uuidString).forwarding"
        }
    }
}

enum KeychainService {
    static let service = "local.selectiveremote.credentials"

    static func credentialReference(
        profileID: UUID,
        kind: KeychainCredentialKind
    ) -> KeychainCredentialReference {
        KeychainCredentialReference(
            service: service,
            account: kind.account(profileID: profileID)
        )
    }

    static func readPassword(
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.account(profileID: profileID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    static func savePassword(
        _ password: String,
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp
    ) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.account(profileID: profileID)
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8)
        ]

        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var item = key
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    static func deletePassword(
        profileID: UUID,
        kind: KeychainCredentialKind = .rdp
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.account(profileID: profileID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func deleteAllPasswords(profileID: UUID) throws {
        try deletePassword(profileID: profileID, kind: .rdp)
        try deletePassword(profileID: profileID, kind: .gateway)
        try deletePassword(profileID: profileID, kind: .ssh)
    }
}

struct KeychainCredentialReference: Equatable, Sendable {
    let service: String
    let account: String
}
