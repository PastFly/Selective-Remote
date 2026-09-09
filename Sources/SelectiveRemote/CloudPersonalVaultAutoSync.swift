import CryptoKit
import Foundation
import Security

struct SelectiveRemotePersonalVaultKeyMaterial: Codable, Equatable, Sendable {
    let vaultID: UUID
    let vaultKey: Data
    let wrappedKey: SelectiveRemotePersonalVaultWrappedKey
    var revision: Int
    var documentHash: Data
    let includesCredentials: Bool

    init(
        vaultID: UUID,
        vaultKey: Data,
        wrappedKey: SelectiveRemotePersonalVaultWrappedKey,
        revision: Int,
        documentHash: Data,
        includesCredentials: Bool = false
    ) throws {
        guard vaultID.isSelectiveRemoteCloudUUID, vaultKey.count == 32,
              revision > 0, documentHash.count == 32
        else { throw SelectiveRemotePersonalVaultError.invalidEnvelope }
        self.vaultID = vaultID
        self.vaultKey = vaultKey
        self.wrappedKey = wrappedKey
        self.revision = revision
        self.documentHash = documentHash
        self.includesCredentials = includesCredentials
    }
}

protocol SelectiveRemotePersonalVaultKeyStore: Sendable {
    func material(endpoint: URL, deviceID: UUID) throws -> SelectiveRemotePersonalVaultKeyMaterial?
    func save(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID) throws
    func remove(endpoint: URL, deviceID: UUID) throws
}

struct SelectiveRemotePersonalVaultKeychainStore: SelectiveRemotePersonalVaultKeyStore {
    static let service = "local.selectiveremote.cloud.personal-vault-key.v1"

    func material(endpoint: URL, deviceID: UUID) throws -> SelectiveRemotePersonalVaultKeyMaterial? {
        let query = baseQuery(endpoint: endpoint, deviceID: deviceID).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw status == errSecSuccess ? KeychainError.invalidData : KeychainError.unexpectedStatus(status)
        }
        do { return try JSONDecoder().decode(SelectiveRemotePersonalVaultKeyMaterial.self, from: data) }
        catch { throw KeychainError.invalidData }
    }

    func save(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID) throws {
        let data = try JSONEncoder().encode(material)
        let query = baseQuery(endpoint: endpoint, deviceID: deviceID)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }
        let item = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func remove(endpoint: URL, deviceID: UUID) throws {
        let status = SecItemDelete(baseQuery(endpoint: endpoint, deviceID: deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(endpoint: URL, deviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(endpoint.absoluteString)|\(deviceID.uuidString.lowercased())"
        ]
    }
}

actor SelectiveRemotePersonalVaultAutoSync {
    private let client: SelectiveRemoteCloudAPIClient
    private let keyStore: any SelectiveRemotePersonalVaultKeyStore
    private var pending: Task<Void, Never>?

    init(
        client: SelectiveRemoteCloudAPIClient = .init(),
        keyStore: any SelectiveRemotePersonalVaultKeyStore = SelectiveRemotePersonalVaultKeychainStore()
    ) {
        self.client = client
        self.keyStore = keyStore
    }

    func schedule(
        endpoint: URL,
        deviceID: UUID,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward]
    ) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? await synchronize(
                endpoint: endpoint,
                deviceID: deviceID,
                profiles: profiles,
                snippets: snippets,
                forwarding: forwarding
            )
        }
    }

    private func synchronize(
        endpoint: URL,
        deviceID: UUID,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward]
    ) async throws {
        guard var material = try keyStore.material(endpoint: endpoint, deviceID: deviceID),
              !material.includesCredentials,
              await client.hasStoredSession(endpoint: endpoint)
        else { return }
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: profiles,
            credentials: [],
            snippets: snippets,
            forwarding: forwarding,
            deviceID: deviceID,
            allowEmpty: true
        )
        let documentHash = Data(SHA256.hash(data: try exported.document.encoded()))
        guard documentHash != material.documentHash else { return }
        let remote = try await client.personalVault(endpoint: endpoint)
        guard remote.id == material.vaultID, remote.revision == material.revision else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
        }
        let envelope = try SelectiveRemotePersonalVaultCrypto.reseal(
            exported.document,
            vaultKey: material.vaultKey,
            wrappedKey: material.wrappedKey,
            baseRevision: remote.revision
        )
        let result = try await client.putPersonalVault(endpoint: endpoint, envelope: envelope)
        guard !result.conflict, result.revision == remote.revision + 1 else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(result.revision)
        }
        material.revision = result.revision
        material.documentHash = documentHash
        try keyStore.save(material, endpoint: endpoint, deviceID: deviceID)
    }
}
