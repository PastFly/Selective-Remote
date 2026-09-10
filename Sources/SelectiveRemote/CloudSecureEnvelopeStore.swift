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
    static let service = "local.selectiveremote.cloud.secure-envelope.v1"
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
        return envelope
    }

    private func writeUnlocked(
        _ envelope: SelectiveRemoteCloudSecureEnvelope,
        endpoint: URL
    ) throws {
        let data = try JSONEncoder().encode(envelope)
        let query = baseQuery(endpoint: endpoint)
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(update)
        }

        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(addition as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw KeychainError.unexpectedStatus(add)
        }
    }

    private func deleteUnlocked(endpoint: URL) throws {
        let status = SecItemDelete(baseQuery(endpoint: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: endpoint.absoluteString
        ]
    }

    private static func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
