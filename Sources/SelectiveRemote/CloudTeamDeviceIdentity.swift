import CryptoKit
import Foundation
import Security

protocol SelectiveRemoteTeamDeviceKeyStore: Sendable {
    func privateKeyRepresentation(for endpoint: URL, deviceID: UUID) throws -> Data?
    func savePrivateKeyIfAbsent(_ representation: Data, for endpoint: URL, deviceID: UUID) throws -> Data
    func removePrivateKey(for endpoint: URL, deviceID: UUID) throws
}

struct SelectiveRemoteTeamDeviceIdentity: @unchecked Sendable {
    let deviceID: UUID
    let publicKey: SelectiveRemoteTeamDevicePublicKey
    let privateKey: P256.KeyAgreement.PrivateKey

    init(deviceID: UUID, privateKeyRepresentation: Data) throws {
        guard deviceID.isSelectiveRemoteCloudUUID, privateKeyRepresentation.count == 32 else {
            throw SelectiveRemoteTeamCryptoError.invalidPrivateKey
        }
        do {
            let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRepresentation)
            self.deviceID = deviceID
            self.publicKey = try SelectiveRemoteTeamDevicePublicKey(privateKey.publicKey)
            self.privateKey = privateKey
        } catch let error as SelectiveRemoteTeamCryptoError {
            throw error
        } catch {
            throw SelectiveRemoteTeamCryptoError.invalidPrivateKey
        }
    }
}

actor SelectiveRemoteTeamDeviceIdentityManager {
    private let store: any SelectiveRemoteTeamDeviceKeyStore

    init(store: any SelectiveRemoteTeamDeviceKeyStore = SelectiveRemoteTeamDeviceKeychainStore()) {
        self.store = store
    }

    func identity(endpoint: URL, deviceID: UUID) throws -> SelectiveRemoteTeamDeviceIdentity {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        if let stored = try store.privateKeyRepresentation(for: endpoint, deviceID: deviceID) {
            return try SelectiveRemoteTeamDeviceIdentity(deviceID: deviceID, privateKeyRepresentation: stored)
        }
        let generated = P256.KeyAgreement.PrivateKey()
        let committed = try store.savePrivateKeyIfAbsent(
            generated.rawRepresentation,
            for: endpoint,
            deviceID: deviceID
        )
        return try SelectiveRemoteTeamDeviceIdentity(deviceID: deviceID, privateKeyRepresentation: committed)
    }

    func removeIdentity(endpoint: URL, deviceID: UUID) throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        try store.removePrivateKey(for: endpoint, deviceID: deviceID)
    }
}

struct SelectiveRemoteTeamDeviceKeychainStore: SelectiveRemoteTeamDeviceKeyStore {
    static let service = "local.selectiveremote.cloud.team-device-key.v1"

    func privateKeyRepresentation(for endpoint: URL, deviceID: UUID) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(endpoint: endpoint, deviceID: deviceID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return data
    }

    func savePrivateKeyIfAbsent(
        _ representation: Data,
        for endpoint: URL,
        deviceID: UUID
    ) throws -> Data {
        guard representation.count == 32 else { throw SelectiveRemoteTeamCryptoError.invalidPrivateKey }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(endpoint: endpoint, deviceID: deviceID),
            kSecValueData as String: representation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return representation }
        if status == errSecDuplicateItem,
           let existing = try privateKeyRepresentation(for: endpoint, deviceID: deviceID) {
            return existing
        }
        throw KeychainError.unexpectedStatus(status)
    }

    func removePrivateKey(for endpoint: URL, deviceID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(endpoint: endpoint, deviceID: deviceID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func account(endpoint: URL, deviceID: UUID) -> String {
        "\(endpoint.absoluteString)|\(deviceID.uuidString.lowercased())"
    }
}

final class SelectiveRemoteTeamDeviceMemoryKeyStore: SelectiveRemoteTeamDeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    func privateKeyRepresentation(for endpoint: URL, deviceID: UUID) -> Data? {
        lock.withLock { keys[account(endpoint: endpoint, deviceID: deviceID)] }
    }

    func savePrivateKeyIfAbsent(
        _ representation: Data,
        for endpoint: URL,
        deviceID: UUID
    ) throws -> Data {
        guard representation.count == 32 else {
            throw SelectiveRemoteTeamCryptoError.invalidPrivateKey
        }
        return lock.withLock {
            let account = account(endpoint: endpoint, deviceID: deviceID)
            if let existing = keys[account] { return existing }
            keys[account] = representation
            return representation
        }
    }

    func removePrivateKey(for endpoint: URL, deviceID: UUID) {
        lock.withLock { keys.removeValue(forKey: account(endpoint: endpoint, deviceID: deviceID)) }
    }

    private func account(endpoint: URL, deviceID: UUID) -> String {
        "\(endpoint.absoluteString)|\(deviceID.uuidString.lowercased())"
    }
}
