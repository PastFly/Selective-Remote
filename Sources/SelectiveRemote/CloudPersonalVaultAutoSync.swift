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
        let value: String
        if let error = error as? SelectiveRemotePersonalVaultError {
            switch error {
            case .invalidRecoveryPhrase: value = "personalVault.invalidRecoveryPhrase"
            case .invalidEnvelope: value = "personalVault.invalidEnvelope"
            case .cryptoFailure: value = "personalVault.cryptoFailure"
            case .emptyLocalVault: value = "personalVault.emptyLocalVault"
            case let .remoteVaultNotEmpty(revision): value = "personalVault.remoteVaultNotEmpty:\(revision)"
            case .legacyMigrationRequiresLocalData: value = "personalVault.legacyMigrationRequiresLocalData"
            case let .uploadConflict(revision): value = "personalVault.uploadConflict:\(revision)"
            }
        } else {
            value = error.localizedDescription
        }
        UserDefaults.standard.set(value, forKey: errorKey)
    }

    static func message(for storedValue: String) -> String {
        let pieces = storedValue.split(separator: ":", maxSplits: 1).map(String.init)
        let revision = pieces.count == 2 ? Int(pieces[1]) : nil
        let error: SelectiveRemotePersonalVaultError?
        switch pieces.first {
        case "personalVault.invalidRecoveryPhrase": error = .invalidRecoveryPhrase
        case "personalVault.invalidEnvelope": error = .invalidEnvelope
        case "personalVault.cryptoFailure": error = .cryptoFailure
        case "personalVault.emptyLocalVault": error = .emptyLocalVault
        case "personalVault.remoteVaultNotEmpty": error = revision.map { .remoteVaultNotEmpty($0) }
        case "personalVault.legacyMigrationRequiresLocalData": error = .legacyMigrationRequiresLocalData
        case "personalVault.uploadConflict": error = revision.map { .uploadConflict($0) }
        default: error = nil
        }
        return error?.localizedDescription ?? storedValue
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
    enum EnrollmentError: LocalizedError {
        case existingVaultUnlockFailed

        var errorDescription: String? {
            UpdateLocalization.text(
                ru: "Не удалось открыть существующий Cloud Vault с этим паролем аккаунта. Приложение не заменило Vault и не изменило сохранённые ключи. Проверьте аккаунт и пароль.",
                en: "The existing Cloud Vault could not be unlocked with this account password. The app did not replace the Vault or change saved keys. Check the account and password."
            )
        }
    }

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
                // Unwrap failure cannot distinguish a legacy Recovery wrapper from a changed
                // account password. Local data must not authorize replacing existing ciphertext.
                throw EnrollmentError.existingVaultUnlockFailed
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
    nonisolated private let keyStore: any SelectiveRemotePersonalVaultKeyStore
    private var pending: Task<Void, Never>?
    private struct Account: Hashable {
        let endpoint: URL
        let deviceID: UUID
    }
    private struct UploadState {
        let id: UUID
        let sessionEpoch: UUID
        let vaultID: UUID?
        var issue: SyncIssue?
    }
    private enum UploadResult {
        case unavailable
        case acknowledged(newAppliedMaterial: SelectiveRemotePersonalVaultKeyMaterial?)
    }
    private var unconfirmedUploads: [Account: UploadState] = [:]

    struct Download: Sendable {
        let document: SelectiveRemoteVaultDocument
        let revision: Int
        let documentHash: Data
        fileprivate let sourceMaterial: SelectiveRemotePersonalVaultKeyMaterial
        fileprivate let sessionEpoch: UUID
    }

    enum CheckResult: Sendable {
        case unavailable
        case unconfirmedUpload(issue: SyncIssue?)
        case current(revision: Int)
        case download(Download)
    }

    init(
        client: SelectiveRemoteCloudAPIClient = .init(),
        keyStore: any SelectiveRemotePersonalVaultKeyStore = SelectiveRemotePersonalVaultKeychainStore()
    ) {
        self.client = client
        self.keyStore = keyStore
    }

    @discardableResult
    func schedule(
        endpoint: URL,
        deviceID: UUID,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        sshKeys: [SSHKeyRecord],
        onFailure: (@Sendable (SyncIssue) async -> Void)? = nil
    ) -> Task<Void, Never> {
        pending?.cancel()
        let account = Account(endpoint: endpoint, deviceID: deviceID)
        let uploadID = UUID()
        let sessionEpoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        let vaultID = (try? keyStore.material(endpoint: endpoint, deviceID: deviceID))?.vaultID
        unconfirmedUploads[account] = UploadState(id: uploadID, sessionEpoch: sessionEpoch, vaultID: vaultID)
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            do {
                let result = try await synchronize(
                    endpoint: endpoint,
                    deviceID: deviceID,
                    profiles: profiles,
                    snippets: snippets,
                    forwarding: forwarding,
                    sshKeys: sshKeys,
                    uploadID: uploadID,
                    sessionEpoch: sessionEpoch
                )
                if case let .acknowledged(newAppliedMaterial) = result,
                   unconfirmedUploads[account]?.id == uploadID,
                   SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == sessionEpoch,
                   !Task.isCancelled {
                    if let material = newAppliedMaterial,
                       try keyStore.material(endpoint: endpoint, deviceID: deviceID) != material { return }
                    unconfirmedUploads.removeValue(forKey: account)
                    if let material = newAppliedMaterial {
                        SelectiveRemotePersonalVaultSyncStatus.recordSuccess(revision: material.revision)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard unconfirmedUploads[account]?.id == uploadID,
                      SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == sessionEpoch,
                      !Task.isCancelled else { return }
                let issue = SyncIssue.classifyPersonal(error)
                unconfirmedUploads[account]?.issue = issue
                SelectiveRemotePersonalVaultSyncStatus.recordError(error)
                await onFailure?(issue)
            }
        }
        return pending!
    }

    func checkForChanges(endpoint: URL, deviceID: UUID) async throws -> CheckResult {
        let sessionEpoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        guard let material = try keyStore.material(endpoint: endpoint, deviceID: deviceID),
              material.allowsUpload,
              await client.hasStoredSession(endpoint: endpoint)
        else { return .unavailable }
        let remote = try await client.personalVault(endpoint: endpoint)
        guard await client.hasStoredSession(endpoint: endpoint),
              SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == sessionEpoch,
              try keyStore.material(endpoint: endpoint, deviceID: deviceID) == material
        else { return .unavailable }
        guard remote.id == material.vaultID else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
        }
        guard remote.revision >= material.revision else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
        }
        // An unchanged server revision says nothing about a queued or failed local PUT.
        // Keep local changes protected until their outgoing snapshot is acknowledged.
        if let upload = unconfirmedUploads[Account(endpoint: endpoint, deviceID: deviceID)],
           upload.sessionEpoch == sessionEpoch || upload.vaultID == nil || upload.vaultID == material.vaultID {
            return .unconfirmedUpload(issue: upload.issue)
        }
        // A former session's different Vault cannot block this one. Keep that
        // unacknowledged state; switching accounts does not confirm its upload.
        if remote.revision == material.revision {
            return .current(revision: remote.revision)
        }
        guard let envelope = remote.envelope else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let document = try SelectiveRemotePersonalVaultCrypto.open(
            envelope,
            vaultKey: material.vaultKey
        )
        return .download(Download(
            document: document,
            revision: remote.revision,
            documentHash: Data(SHA256.hash(data: try document.encoded())),
            sourceMaterial: material,
            sessionEpoch: sessionEpoch
        ))
    }

    @MainActor
    func acceptDownload(
        _ download: Download, endpoint: URL, deviceID: UUID,
        apply: @MainActor () throws -> Bool
    ) throws -> Bool {
        guard !Task.isCancelled,
              SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == download.sessionEpoch,
              try keyStore.material(endpoint: endpoint, deviceID: deviceID) == download.sourceMaterial,
              download.revision > download.sourceMaterial.revision
        else { return false }
        // Apply and acknowledge synchronously on MainActor: no actor hop may publish
        // the revision before the UI has actually persisted and applied its snapshot.
        guard try apply(),
              SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == download.sessionEpoch,
              try keyStore.material(endpoint: endpoint, deviceID: deviceID) == download.sourceMaterial
        else { return false }
        var material = download.sourceMaterial
        material.revision = download.revision
        material.documentHash = download.documentHash
        material.requiresInitialDownload = false
        try keyStore.save(material, endpoint: endpoint, deviceID: deviceID)
        return true
    }

    private func synchronize(
        endpoint: URL,
        deviceID: UUID,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        sshKeys: [SSHKeyRecord],
        uploadID: UUID,
        sessionEpoch: UUID
    ) async throws -> UploadResult {
        guard var material = try keyStore.material(endpoint: endpoint, deviceID: deviceID),
              material.allowsUpload,
              await client.hasStoredSession(endpoint: endpoint)
        else { return .unavailable }
        let account = Account(endpoint: endpoint, deviceID: deviceID)
        let expectedMaterial = material
        try requireCurrentUpload(expectedMaterial, account: account, id: uploadID, epoch: sessionEpoch)
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
        try requireCurrentUpload(expectedMaterial, account: account, id: uploadID, epoch: sessionEpoch)
        let remote = try await client.personalVault(endpoint: endpoint)
        try requireCurrentUpload(expectedMaterial, account: account, id: uploadID, epoch: sessionEpoch)
        guard remote.id == material.vaultID else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
        }
        let concurrentChange = remote.revision != material.revision
        let document = concurrentChange
            ? try mergeConcurrent(
                local: exported.document,
                remote: remote,
                vaultKey: material.vaultKey,
                deviceID: deviceID
            )
            : try mergedDocument(
                local: exported.document,
                remote: remote,
                vaultKey: material.vaultKey,
                profileIDs: Set(profiles.map(\.id))
            )
        let documentHash = Data(SHA256.hash(data: try document.encoded()))
        guard documentHash != material.documentHash else {
            return .acknowledged(newAppliedMaterial: nil)
        }
        let envelope = try SelectiveRemotePersonalVaultCrypto.reseal(
            document,
            vaultKey: material.vaultKey,
            wrappedKey: material.wrappedKey,
            baseRevision: remote.revision
        )
        try requireCurrentUpload(expectedMaterial, account: account, id: uploadID, epoch: sessionEpoch)
        let result = try await client.putPersonalVault(endpoint: endpoint, envelope: envelope)
        try requireCurrentUpload(expectedMaterial, account: account, id: uploadID, epoch: sessionEpoch)
        guard !result.conflict, result.revision == remote.revision + 1 else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(result.revision)
        }
        // Keep the previous revision after a concurrent merge. The inbound loop
        // then materializes that exact merged revision on this Mac as well.
        if concurrentChange { return .acknowledged(newAppliedMaterial: nil) }
        material.revision = result.revision
        material.documentHash = documentHash
        try keyStore.save(material, endpoint: endpoint, deviceID: deviceID)
        return .acknowledged(newAppliedMaterial: material)
    }

    private func requireCurrentUpload(
        _ material: SelectiveRemotePersonalVaultKeyMaterial,
        account: Account, id: UUID, epoch: UUID
    ) throws {
        guard !Task.isCancelled, let upload = unconfirmedUploads[account], upload.id == id,
              upload.sessionEpoch == epoch,
              upload.vaultID == nil || upload.vaultID == material.vaultID,
              SelectiveRemotePublicationLifecycle.epoch(endpoint: account.endpoint) == epoch,
              try keyStore.material(endpoint: account.endpoint, deviceID: account.deviceID) == material
        else { throw CancellationError() }
    }

    private func mergeConcurrent(
        local: SelectiveRemoteVaultDocument,
        remote: SelectiveRemoteCloudPersonalVault,
        vaultKey: Data,
        deviceID: UUID
    ) throws -> SelectiveRemoteVaultDocument {
        guard let envelope = remote.envelope else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let current = try SelectiveRemotePersonalVaultCrypto.open(envelope, vaultKey: vaultKey)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try local.mergedKeepingNewest(
            with: current,
            deviceID: deviceID,
            resolvedAt: formatter.string(from: Date())
        ).document
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
                && (isStandaloneCredential($0)
                    || credentialSourceID($0).map(profileIDs.contains) == true)
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

    private func isStandaloneCredential(_ record: SelectiveRemoteVaultRecord) -> Bool {
        guard case let .object(data) = record.data else { return false }
        return data["sourceID"] == nil && data["kind"] == nil
    }
}
