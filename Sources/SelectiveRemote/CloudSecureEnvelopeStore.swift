import Foundation
import Security

struct SelectiveRemoteCloudSecureEnvelope: Codable, Equatable {
    var sessionToken: String?
    var teamDevicePrivateKeys: [String: Data]
    var personalVaultKeyMaterials: [String: Data]

    init(
        sessionToken: String? = nil,
        teamDevicePrivateKeys: [String: Data] = [:],
        personalVaultKeyMaterials: [String: Data] = [:]
    ) {
        self.sessionToken = sessionToken
        self.teamDevicePrivateKeys = teamDevicePrivateKeys
        self.personalVaultKeyMaterials = personalVaultKeyMaterials
    }

    var isEmpty: Bool {
        sessionToken == nil
            && teamDevicePrivateKeys.isEmpty
            && personalVaultKeyMaterials.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case sessionToken, teamDevicePrivateKeys, personalVaultKeyMaterials
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionToken = try values.decodeIfPresent(String.self, forKey: .sessionToken)
        teamDevicePrivateKeys = try values.decodeIfPresent(
            [String: Data].self,
            forKey: .teamDevicePrivateKeys
        ) ?? [:]
        personalVaultKeyMaterials = try values.decodeIfPresent(
            [String: Data].self,
            forKey: .personalVaultKeyMaterials
        ) ?? [:]
    }
}

struct SelectiveRemoteCloudSecureEnvelopeStore {
    static let legacyService = "local.selectiveremote.cloud.secure-envelope.v1"
    static let namespace = "cloud-secure-envelope.v1"
    private static let lock = NSLock()

    func envelope(for endpoint: URL) throws -> SelectiveRemoteCloudSecureEnvelope? {
        try Self.synchronized {
            try readUnlocked(endpoint: endpoint)
        }
    }

    func update(
        for endpoint: URL,
        _ mutation: (inout SelectiveRemoteCloudSecureEnvelope) throws -> Void
    ) throws {
        try Self.synchronized {
            var envelope = try readUnlocked(endpoint: endpoint) ?? .init()
            try mutation(&envelope)
            if envelope.isEmpty {
                try deleteUnlocked(endpoint: endpoint)
            } else {
                try writeUnlocked(envelope, endpoint: endpoint)
            }
        }
    }

    private func readUnlocked(endpoint: URL) throws -> SelectiveRemoteCloudSecureEnvelope? {
        if let data = try UnifiedCredentialVault.shared.readProtectedData(
            namespace: Self.namespace,
            key: endpoint.absoluteString
        ) {
            guard let envelope = try? JSONDecoder().decode(
                SelectiveRemoteCloudSecureEnvelope.self,
                from: data
            ) else { throw KeychainError.invalidData }
            return envelope
        }

        // One-time migration from the former Cloud-only Keychain item. The old
        // item is deleted only after the unified vault has been persisted.
        var query = baseQuery(endpoint: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let envelope = try? JSONDecoder().decode(
                  SelectiveRemoteCloudSecureEnvelope.self,
                  from: data
              )
        else { throw KeychainError.invalidData }
        try UnifiedCredentialVault.shared.saveProtectedData(
            data,
            namespace: Self.namespace,
            key: endpoint.absoluteString
        )
        try? deleteLegacyUnlocked(endpoint: endpoint)
        return envelope
    }

    private func writeUnlocked(
        _ envelope: SelectiveRemoteCloudSecureEnvelope,
        endpoint: URL
    ) throws {
        let data = try JSONEncoder().encode(envelope)
        try UnifiedCredentialVault.shared.saveProtectedData(
            data,
            namespace: Self.namespace,
            key: endpoint.absoluteString
        )
        try? deleteLegacyUnlocked(endpoint: endpoint)
    }

    private func deleteUnlocked(endpoint: URL) throws {
        try UnifiedCredentialVault.shared.deleteProtectedData(
            namespace: Self.namespace,
            key: endpoint.absoluteString
        )
        try? deleteLegacyUnlocked(endpoint: endpoint)
    }

    private func deleteLegacyUnlocked(endpoint: URL) throws {
        let status = SecItemDelete(baseQuery(endpoint: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyService,
            kSecAttrAccount as String: endpoint.absoluteString
        ]
    }

    private static func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
