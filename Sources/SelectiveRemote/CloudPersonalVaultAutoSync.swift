import CryptoKit
import Foundation
import Security

enum SelectiveRemotePersonalVaultSyncStatus {
    static let lastSuccessKey = "SelectiveRemote.cloud.personal-vault-sync-last-success.v1"
    static let revisionKey = "SelectiveRemote.cloud.personal-vault-sync-revision.v1"
    static let errorKey = "SelectiveRemote.cloud.personal-vault-sync-error.v1"
    static let isSyncingKey = "SelectiveRemote.cloud.personal-vault-sync-active.v1"

    static func recordSuccess(revision: Int) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: lastSuccessKey)
        defaults.set(revision, forKey: revisionKey)
        defaults.removeObject(forKey: errorKey)
    }

    static func recordError(_ error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: errorKey)
    }
}

struct SelectiveRemotePersonalVaultKeyMaterial: Codable, Equatable, Sendable {
    let vaultID: UUID
    let vaultKey: Data
    let wrappedKey: SelectiveRemotePersonalVaultWrappedKey
    var revision: Int
    var documentHash: Data
    let includesCredentials: Bool
    var requiresInitialDownload: Bool?

    var allowsUpload: Bool { requiresInitialDownload != true }

    init(
        vaultID: UUID,
        vaultKey: Data,
        wrappedKey: SelectiveRemotePersonalVaultWrappedKey,
        revision: Int,
        documentHash: Data,
        includesCredentials: Bool = false,
        requiresInitialDownload: Bool = false
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
        self.requiresInitialDownload = requiresInitialDownload
    }
}

protocol SelectiveRemotePersonalVaultKeyStore: Sendable {
    func material(endpoint: URL, deviceID: UUID) throws -> SelectiveRemotePersonalVaultKeyMaterial?
    func save(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID) throws
    func remove(endpoint: URL, deviceID: UUID) throws
}

struct SelectiveRemotePersonalVaultKeychainStore: SelectiveRemotePersonalVaultKeyStore {
    static let legacyService = "local.selectiveremote.cloud.personal-vault-key.v1"
    static let service = legacyService
    private let envelopeStore = SelectiveRemoteCloudSecureEnvelopeStore()

    func material(endpoint: URL, deviceID: UUID) throws -> SelectiveRemotePersonalVaultKeyMaterial? {
        let key = deviceID.uuidString.lowercased()
        if let data = try envelopeStore.envelope(for: endpoint)?
            .personalVaultKeyMaterials[key] {
            do { return try JSONDecoder().decode(SelectiveRemotePersonalVaultKeyMaterial.self, from: data) }
            catch { throw KeychainError.invalidData }
        }
        let query = legacyQuery(endpoint: endpoint, deviceID: deviceID).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw status == errSecSuccess ? KeychainError.invalidData : KeychainError.unexpectedStatus(status)
        }
        do {
            let material = try JSONDecoder().decode(SelectiveRemotePersonalVaultKeyMaterial.self, from: data)
            try save(material, endpoint: endpoint, deviceID: deviceID)
            try? removeLegacy(endpoint: endpoint, deviceID: deviceID)
            return material
        } catch let error as KeychainError { throw error }
        catch { throw KeychainError.invalidData }
    }

    func save(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID) throws {
        let data = try JSONEncoder().encode(material)
        let key = deviceID.uuidString.lowercased()
        try envelopeStore.update(for: endpoint) {
            $0.personalVaultKeyMaterials[key] = data
        }
    }

    func remove(endpoint: URL, deviceID: UUID) throws {
        let key = deviceID.uuidString.lowercased()
        try envelopeStore.update(for: endpoint) {
            $0.personalVaultKeyMaterials.removeValue(forKey: key)
        }
        try? removeLegacy(endpoint: endpoint, deviceID: deviceID)
    }

    private func removeLegacy(endpoint: URL, deviceID: UUID) throws {
        let status = SecItemDelete(legacyQuery(endpoint: endpoint, deviceID: deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func legacyQuery(endpoint: URL, deviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyService,
            kSecAttrAccount as String: "\(endpoint.absoluteString)|\(deviceID.uuidString.lowercased())"
        ]
    }
}

struct SelectiveRemotePersonalVaultAccountEnrollment {
    let client: SelectiveRemoteCloudAPIClient
    let keyStore: any SelectiveRemotePersonalVaultKeyStore

    init(
        client: SelectiveRemoteCloudAPIClient = .init(),
        keyStore: any SelectiveRemotePersonalVaultKeyStore = SelectiveRemotePersonalVaultKeychainStore()
    ) {
        self.client = client
        self.keyStore = keyStore
    }

    func enrollOrCreate(
        endpoint: URL,
        deviceID: UUID,
        password: String,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        credentials: [SelectiveRemotePersonalVaultCredentialInput] = [],
        sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput] = []
    ) async throws -> Int {
        let passphrase = try SelectiveRemotePersonalVaultCrypto.accountPassphrase(password)
        let remote = try await client.personalVault(endpoint: endpoint)
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: profiles,
            credentials: credentials,
            snippets: snippets,
            forwarding: forwarding,
            sshKeys: sshKeys,
            deviceID: deviceID,
            allowEmpty: true
        )
        let material: SelectiveRemotePersonalVaultKeyMaterial
        if remote.revision == 0 {
            material = try await replaceWithLocalVault(
                endpoint: endpoint,
                remote: remote,
                exported: exported,
                passphrase: passphrase
            )
        } else {
            guard let envelope = remote.envelope else {
                throw SelectiveRemotePersonalVaultError.invalidEnvelope
            }
            do {
                let vaultKey = try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(
                    envelope.wrappedKey,
                    passphrase: passphrase
                )
                let document = try SelectiveRemotePersonalVaultCrypto.open(envelope, vaultKey: vaultKey)
                material = try .init(
                    vaultID: remote.id,
                    vaultKey: vaultKey,
                    wrappedKey: envelope.wrappedKey,
                    revision: remote.revision,
                    documentHash: Data(SHA256.hash(data: try document.encoded())),
                    includesCredentials: document.records.contains { $0.type == .credential },
                    requiresInitialDownload: true
                )
            } catch SelectiveRemotePersonalVaultError.invalidRecoveryPhrase {
                // A legacy Recovery-wrapped revision cannot be opened with account credentials.
                // Make this Mac's complete local snapshot authoritative automatically. The server
                // keeps the previous ciphertext in vault_revisions, so migration is reversible by
                // an administrator without exposing plaintext or asking the user for Recovery.
                material = try await replaceWithLocalVault(
                    endpoint: endpoint,
                    remote: remote,
                    exported: exported,
                    passphrase: passphrase
                )
            }
        }
        try keyStore.save(material, endpoint: endpoint, deviceID: deviceID)
        return material.revision
    }

    private func replaceWithLocalVault(
        endpoint: URL,
        remote: SelectiveRemoteCloudPersonalVault,
        exported: SelectiveRemotePersonalVaultExport,
        passphrase: String
    ) async throws -> SelectiveRemotePersonalVaultKeyMaterial {
        let setup = try SelectiveRemotePersonalVaultCrypto.createSetup(
            exported.document,
            recoveryPhrase: passphrase,
            baseRevision: remote.revision
        )
        let result = try await client.putPersonalVault(endpoint: endpoint, envelope: setup.envelope)
        guard !result.conflict, result.revision == remote.revision + 1 else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(result.revision)
        }
        return try .init(
            vaultID: remote.id,
            vaultKey: setup.vaultKey,
            wrappedKey: setup.envelope.wrappedKey,
            revision: result.revision,
            documentHash: Data(SHA256.hash(data: try exported.document.encoded())),
            includesCredentials: exported.document.records.contains { $0.type == .credential }
        )
    }
}

actor SelectiveRemotePersonalVaultAutoSync {
    private let client: SelectiveRemoteCloudAPIClient
    private let keyStore: any SelectiveRemotePersonalVaultKeyStore
    private var pending: Task<Void, Never>?

    struct Download: Sendable {
        let document: SelectiveRemoteVaultDocument
        let revision: Int
        let documentHash: Data
    }

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
        forwarding: [IndependentPortForward],
        sshKeys: [SSHKeyRecord]
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
                forwarding: forwarding,
                sshKeys: sshKeys
            )
        }
    }

    func downloadIfNewer(endpoint: URL, deviceID: UUID) async throws -> Download? {
        guard let material = try keyStore.material(endpoint: endpoint, deviceID: deviceID),
              material.allowsUpload,
              await client.hasStoredSession(endpoint: endpoint)
        else { return nil }
        let remote = try await client.personalVault(endpoint: endpoint)
        guard remote.id == material.vaultID else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
        }
        guard remote.revision > material.revision else {
            SelectiveRemotePersonalVaultSyncStatus.recordSuccess(revision: remote.revision)
            return nil
        }
        guard let envelope = remote.envelope else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let document = try SelectiveRemotePersonalVaultCrypto.open(
            envelope,
            vaultKey: material.vaultKey
        )
        return Download(
            document: document,
            revision: remote.revision,
            documentHash: Data(SHA256.hash(data: try document.encoded()))
        )
    }

    func acceptDownload(_ download: Download, endpoint: URL, deviceID: UUID) throws {
        guard var material = try keyStore.material(endpoint: endpoint, deviceID: deviceID),
              download.revision > material.revision
        else { return }
        material.revision = download.revision
        material.documentHash = download.documentHash
        material.requiresInitialDownload = false
        try keyStore.save(material, endpoint: endpoint, deviceID: deviceID)
        SelectiveRemotePersonalVaultSyncStatus.recordSuccess(revision: download.revision)
    }

    private func synchronize(
        endpoint: URL,
        deviceID: UUID,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        sshKeys: [SSHKeyRecord]
    ) async throws {
        guard var material = try keyStore.material(endpoint: endpoint, deviceID: deviceID),
              material.allowsUpload,
              await client.hasStoredSession(endpoint: endpoint)
        else { return }
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: profiles,
            credentials: try await SelectiveRemotePersonalVaultCredentialCollector.shared.collect(
                profiles: profiles,
                forwarding: forwarding
            ),
            snippets: snippets,
            forwarding: forwarding,
            sshKeys: try await SelectiveRemotePersonalVaultCredentialCollector.shared.collectSSHKeys(sshKeys),
            deviceID: deviceID,
            allowEmpty: true
        )
        let remote = try await client.personalVault(endpoint: endpoint)
        guard remote.id == material.vaultID else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
        }
        let concurrentChange = remote.revision != material.revision
        let document = concurrentChange
            ? try mergeConcurrent(local: exported.document, remote: remote, vaultKey: material.vaultKey)
            : try mergedDocument(
                local: exported.document,
                remote: remote,
                vaultKey: material.vaultKey,
                profileIDs: Set(profiles.map(\.id))
            )
        let documentHash = Data(SHA256.hash(data: try document.encoded()))
        guard documentHash != material.documentHash else { return }
        let envelope = try SelectiveRemotePersonalVaultCrypto.reseal(
            document,
            vaultKey: material.vaultKey,
            wrappedKey: material.wrappedKey,
            baseRevision: remote.revision
        )
        let result = try await client.putPersonalVault(endpoint: endpoint, envelope: envelope)
        guard !result.conflict, result.revision == remote.revision + 1 else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(result.revision)
        }
        // Keep the previous revision after a concurrent merge. The inbound loop
        // then materializes that exact merged revision on this Mac as well.
        if concurrentChange { return }
        material.revision = result.revision
        material.documentHash = documentHash
        try keyStore.save(material, endpoint: endpoint, deviceID: deviceID)
        SelectiveRemotePersonalVaultSyncStatus.recordSuccess(revision: result.revision)
    }

    private func mergeConcurrent(
        local: SelectiveRemoteVaultDocument,
        remote: SelectiveRemoteCloudPersonalVault,
        vaultKey: Data
    ) throws -> SelectiveRemoteVaultDocument {
        guard let envelope = remote.envelope else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let current = try SelectiveRemotePersonalVaultCrypto.open(envelope, vaultKey: vaultKey)
        var records = Dictionary(uniqueKeysWithValues: current.records.map { ($0.id, $0) })
        for record in local.records {
            if let existing = records[record.id], existing.modifiedAt > record.modifiedAt { continue }
            records[record.id] = record
        }
        var tombstones = Dictionary(uniqueKeysWithValues: current.tombstones.map { ($0.id, $0) })
        for tombstone in local.tombstones {
            if let existing = tombstones[tombstone.id], existing.deletedAt > tombstone.deletedAt { continue }
            tombstones[tombstone.id] = tombstone
        }
        for (id, tombstone) in tombstones {
            if let record = records[id], tombstone.deletedAt >= record.modifiedAt {
                records.removeValue(forKey: id)
            }
        }
        return try .init(
            records: records.values.sorted { $0.id.uuidString < $1.id.uuidString },
            tombstones: tombstones.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private func mergedDocument(
        local: SelectiveRemoteVaultDocument,
        remote: SelectiveRemoteCloudPersonalVault,
        vaultKey: Data,
        profileIDs: Set<UUID>
    ) throws -> SelectiveRemoteVaultDocument {
        guard let envelope = remote.envelope else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let current = try SelectiveRemotePersonalVaultCrypto.open(envelope, vaultKey: vaultKey)
        let localCredentialIDs = Set(local.records.lazy.filter { $0.type == .credential }.map(\.id))
        let credentials = current.records.filter {
            $0.type == .credential
                && !localCredentialIDs.contains($0.id)
                && credentialSourceID($0).map(profileIDs.contains) == true
        }
        return try .init(
            records: local.records + credentials,
            tombstones: current.tombstones
        )
    }

    private func credentialSourceID(_ record: SelectiveRemoteVaultRecord) -> UUID? {
        guard case let .object(data) = record.data,
              case let .string(source)? = data["sourceID"]
        else { return nil }
        return UUID(uuidString: source)
    }
}
