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
            case .legacyStorageNeedsReview: value = "personalVault.legacyStorageNeedsReview"
            case let .uploadConflict(revision): value = "personalVault.uploadConflict:\(revision)"
            }
        } else if error as? SelectiveRemoteCloudError == .personalVaultWriteUnsupported {
            value = AppCopy.personalVaultWriteUnsupported
        } else {
            value = error.localizedDescription
        }
        UserDefaults.standard.set(value, forKey: errorKey)
    }

    static func message(for storedValue: String) -> String {
        if storedValue == AppCopy.personalVaultWriteUnsupported {
            return UpdateLocalization.key(storedValue)
        }
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
        case "personalVault.legacyStorageNeedsReview": error = .legacyStorageNeedsReview
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
    func saveIfCurrent(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID, token: String, replacing: SelectiveRemotePersonalVaultKeyMaterial?) throws
}

extension SelectiveRemotePersonalVaultKeyStore {
    func saveIfCurrent(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID, token: String, replacing expected: SelectiveRemotePersonalVaultKeyMaterial?) throws {
        guard try self.material(endpoint: endpoint, deviceID: deviceID) == expected else { throw CancellationError() }
        try save(material, endpoint: endpoint, deviceID: deviceID)
    }
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
        var selected: SelectiveRemotePersonalVaultKeyMaterial?
        var migrated = false
        try envelopeStore.update(for: endpoint) { envelope in
            if let data = envelope.personalVaultKeyMaterials[key] {
                guard let current = try? JSONDecoder().decode(SelectiveRemotePersonalVaultKeyMaterial.self, from: data) else { throw KeychainError.invalidData }
                selected = current
                return
            }
            let query = legacyQuery(endpoint: endpoint, deviceID: deviceID).merging([
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
            ]) { _, new in new }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess, let data = result as? Data else {
                throw status == errSecSuccess ? KeychainError.invalidData : KeychainError.unexpectedStatus(status)
            }
            guard let material = try? JSONDecoder().decode(SelectiveRemotePersonalVaultKeyMaterial.self, from: data) else { throw KeychainError.invalidData }
            envelope.personalVaultKeyMaterials[key] = data
            selected = material
            migrated = true
        }
        if migrated { try? removeLegacy(endpoint: endpoint, deviceID: deviceID) }
        return selected
    }

    func save(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID) throws {
        let data = try JSONEncoder().encode(material)
        let key = deviceID.uuidString.lowercased()
        try envelopeStore.update(for: endpoint) {
            $0.personalVaultKeyMaterials[key] = data
        }
    }

    func saveIfCurrent(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID, token: String, replacing expected: SelectiveRemotePersonalVaultKeyMaterial?) throws {
        let data = try JSONEncoder().encode(material)
        let key = deviceID.uuidString.lowercased()
        try envelopeStore.update(for: endpoint) { envelope in
            guard envelope.sessionToken == token else { throw CancellationError() }
            let current = try envelope.personalVaultKeyMaterials[key].map {
                try JSONDecoder().decode(SelectiveRemotePersonalVaultKeyMaterial.self, from: $0)
            }
            guard current == expected else { throw CancellationError() }
            envelope.personalVaultKeyMaterials[key] = data
        }
    }

    func remove(endpoint: URL, deviceID: UUID) throws {
        let key = deviceID.uuidString.lowercased()
        try envelopeStore.update(for: endpoint) {
            try removeLegacy(endpoint: endpoint, deviceID: deviceID)
            $0.personalVaultKeyMaterials.removeValue(forKey: key)
        }
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
        case vaultNotInitialized

        var errorDescription: String? {
            switch self {
            case .existingVaultUnlockFailed:
                UpdateLocalization.text(
                    ru: "Не удалось открыть личный Vault. Проверьте пароль, с которым он был настроен, или используйте его фразу восстановления.",
                    en: "Could not unlock Personal Vault. Check the password used to set it up, or use its recovery phrase."
                )
            case .vaultNotInitialized:
                UpdateLocalization.text(
                    ru: "Личный Vault ещё не создан. Обновите настройки Cloud и выполните первоначальную настройку.",
                    en: "Personal Vault has not been created yet. Refresh Cloud Settings and complete initial setup."
                )
            }
        }
    }

    enum UnlockMethod: Sendable, CaseIterable {
        case accountPassword, recoveryPhrase
    }

    struct DeferredEnrollment: Error {
        fileprivate let wrappingKey: SelectiveRemotePersonalVaultCrypto.InitialWrappingKey
        fileprivate let session: SelectiveRemoteCloudSessionBinding
        fileprivate let deviceID: UUID
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
        accountID: UUID,
        session: SelectiveRemoteCloudSessionBinding,
        password: String,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        collectUploadSecrets: @MainActor @Sendable () async throws -> (
            credentials: [SelectiveRemotePersonalVaultCredentialInput],
            sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput]
        ) = { ([], []) },
        deferIfUnavailable: Bool = false
    ) async throws -> Int {
        let expectedMaterial = try keyStore.material(endpoint: endpoint, deviceID: deviceID)
        let passphrase = try SelectiveRemotePersonalVaultCrypto.accountPassphrase(password)
        guard session.endpoint == endpoint else { throw CancellationError() }
        let remote = try await client.personalVault(endpoint: endpoint, session: session)
        if remote.revision == 0 {
            let wrappingKey = try await Task.detached(priority: .userInitiated) {
                try SelectiveRemotePersonalVaultCrypto.InitialWrappingKey(accountID: accountID, vaultID: remote.id, passphrase: passphrase)
            }.value
            let initial = DeferredEnrollment(wrappingKey: wrappingKey, session: session, deviceID: deviceID)
            do {
                return try await completeInitialEnrollment(
                    initial, remote: remote, expectedMaterial: expectedMaterial,
                    profiles: profiles, snippets: snippets, forwarding: forwarding,
                    collectUploadSecrets: collectUploadSecrets, interactivePassphrase: passphrase
                )
            } catch let error as SelectiveRemoteCloudError
                        where deferIfUnavailable && error == .serviceError(503, "vault_write_temporarily_unavailable") {
                try await client.checkSession(session)
                throw initial
            }
        }
        let material = try await Self.unlockedMaterial(remote) { wrapped in
            try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(wrapped, passphrase: passphrase)
        }
        return try await saveEnrollment(material, session: session, deviceID: deviceID, expectedMaterial: expectedMaterial)
    }

    func resumeInitialEnrollment(
        _ initial: DeferredEnrollment,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        collectUploadSecrets: @MainActor @Sendable () async throws -> (
            credentials: [SelectiveRemotePersonalVaultCredentialInput],
            sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput]
        ) = { ([], []) }
    ) async throws -> Int {
        let remote = try await client.personalVault(endpoint: initial.session.endpoint, session: initial.session)
        let expected = try keyStore.material(endpoint: initial.session.endpoint, deviceID: initial.deviceID)
        return try await completeInitialEnrollment(
            initial, remote: remote, expectedMaterial: expected, profiles: profiles,
            snippets: snippets, forwarding: forwarding, collectUploadSecrets: collectUploadSecrets
        )
    }

    private func completeInitialEnrollment(
        _ initial: DeferredEnrollment,
        remote: SelectiveRemoteCloudPersonalVault,
        expectedMaterial: SelectiveRemotePersonalVaultKeyMaterial?,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        collectUploadSecrets: @MainActor @Sendable () async throws -> (
            credentials: [SelectiveRemotePersonalVaultCredentialInput],
            sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput]
        ),
        interactivePassphrase: String? = nil
    ) async throws -> Int {
        let session = initial.session
        let wrappingKey = initial.wrappingKey
        guard remote.id == wrappingKey.vaultID else { throw EnrollmentError.existingVaultUnlockFailed }
        let material: SelectiveRemotePersonalVaultKeyMaterial
        if remote.revision > 0 {
            material = try await Self.unlockedMaterial(remote, unwrap: wrappingKey.unwrap)
        } else {
            guard expectedMaterial == nil else { throw SelectiveRemotePersonalVaultError.invalidEnvelope }
            try await client.requireV1WriteFence(endpoint: session.endpoint, session: session, personal: true)
            let secrets = try await collectUploadSecrets()
            try Task.checkCancellation()
            try await client.checkSession(session)
            let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
                profiles: profiles, credentials: secrets.credentials, snippets: snippets,
                forwarding: forwarding, sshKeys: secrets.sshKeys, deviceID: initial.deviceID, allowEmpty: true
            )
            do {
                material = try await replaceWithLocalVault(
                    vaultID: remote.id, exported: exported, session: session, wrappingKey: wrappingKey
                )
            } catch SelectiveRemotePersonalVaultError.uploadConflict(let revision) where revision > 0 {
                let winner = try await client.personalVault(endpoint: session.endpoint, session: session)
                guard winner.id == wrappingKey.vaultID, winner.revision >= revision else {
                    throw SelectiveRemotePersonalVaultError.invalidEnvelope
                }
                material = try await Self.unlockedMaterial(winner) { wrapped in
                    if let interactivePassphrase,
                       wrapped.salt != wrappingKey.encodedSalt {
                        return try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(wrapped, passphrase: interactivePassphrase)
                    }
                    return try wrappingKey.unwrap(wrapped)
                }
            }
        }
        return try await saveEnrollment(
            material, session: session, deviceID: initial.deviceID, expectedMaterial: expectedMaterial
        )
    }

    private func saveEnrollment(
        _ material: SelectiveRemotePersonalVaultKeyMaterial,
        session: SelectiveRemoteCloudSessionBinding,
        deviceID: UUID,
        expectedMaterial: SelectiveRemotePersonalVaultKeyMaterial?
    ) async throws -> Int {
        try Task.checkCancellation()
        if let expectedMaterial, expectedMaterial.allowsUpload,
           expectedMaterial.vaultID == material.vaultID,
           expectedMaterial.vaultKey == material.vaultKey,
           expectedMaterial.wrappedKey == material.wrappedKey,
           expectedMaterial.revision <= material.revision,
           expectedMaterial.revision < material.revision || expectedMaterial.documentHash == material.documentHash {
            // Keep the last applied revision so the normal sync can fetch any newer data.
            try await client.checkSession(session)
            return expectedMaterial.revision
        }
        try await client.savePersonalVaultMaterial(material, session: session, deviceID: deviceID, keyStore: keyStore, replacing: expectedMaterial)
        return material.revision
    }

    func unlockExistingVault(
        session: SelectiveRemoteCloudSessionBinding,
        deviceID: UUID,
        secret: String,
        method: UnlockMethod
    ) async throws {
        let passphrase: String
        switch method {
        case .accountPassword:
            passphrase = try SelectiveRemotePersonalVaultCrypto.accountPassphrase(secret)
        case .recoveryPhrase:
            guard (16...1_024).contains(secret.precomposedStringWithCanonicalMapping.utf8.count) else {
                throw SelectiveRemotePersonalVaultError.invalidRecoveryPhrase
            }
            passphrase = secret
        }
        let endpoint = session.endpoint
        let expectedMaterial = try keyStore.material(endpoint: endpoint, deviceID: deviceID)
        let remote = try await client.personalVault(endpoint: endpoint, session: session)
        let material = try await Self.unlockedMaterial(remote) { wrapped in
            try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(wrapped, passphrase: passphrase)
        }
        try await client.savePersonalVaultMaterial(
            material, session: session, deviceID: deviceID, keyStore: keyStore, replacing: expectedMaterial
        )
    }

    private static func unlockedMaterial(
        _ remote: SelectiveRemoteCloudPersonalVault,
        unwrap: @escaping @Sendable (SelectiveRemotePersonalVaultWrappedKey) throws -> Data
    ) async throws -> SelectiveRemotePersonalVaultKeyMaterial {
        guard remote.revision > 0 else { throw EnrollmentError.vaultNotInitialized }
        guard let envelope = remote.envelope else { throw SelectiveRemotePersonalVaultError.invalidEnvelope }
        return try await Task.detached(priority: .userInitiated) {
            do {
                let vaultKey = try unwrap(envelope.wrappedKey)
                let document = try SelectiveRemotePersonalVaultCrypto.open(envelope, vaultKey: vaultKey)
                return try SelectiveRemotePersonalVaultKeyMaterial(
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
        }.value
    }

    private func replaceWithLocalVault(
        vaultID: UUID,
        exported: SelectiveRemotePersonalVaultExport,
        session: SelectiveRemoteCloudSessionBinding,
        wrappingKey: SelectiveRemotePersonalVaultCrypto.InitialWrappingKey
    ) async throws -> SelectiveRemotePersonalVaultKeyMaterial {
        let setup = try wrappingKey.createSetup(exported.document)
        try Task.checkCancellation()
        let result = try await client.putPersonalVault(endpoint: session.endpoint, envelope: setup.envelope, session: session)
        guard !result.conflict, result.revision == 1 else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(result.revision)
        }
        return try .init(
            vaultID: vaultID,
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
        let editDates: [UUID: Date]
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
        fileprivate let session: SelectiveRemoteCloudSessionBinding
    }

    enum CheckResult: Sendable {
        case unavailable
        case signedOut
        case setupRequired
        case initialDownloadRequired(Download?)
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
        expectedSessionEpoch: UUID,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        sshKeys: [SSHKeyRecord],
        editDates: [UUID: Date] = [:],
        legacyAppliedRevision: Int? = nil,
        onFailure: (@Sendable (SyncIssue) async -> Void)? = nil
    ) -> Task<Void, Never> {
        guard SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == expectedSessionEpoch else {
            return Task { }
        }
        pending?.cancel()
        let account = Account(endpoint: endpoint, deviceID: deviceID)
        let uploadID = UUID()
        let sessionEpoch = expectedSessionEpoch
        let vaultID = (try? keyStore.material(endpoint: endpoint, deviceID: deviceID))?.vaultID
        let previous = unconfirmedUploads[account]
        let previousDates = previous?.sessionEpoch == sessionEpoch && previous?.vaultID == vaultID
            ? previous?.editDates ?? [:] : [:]
        let dates = previousDates.merging(editDates, uniquingKeysWith: max)
        unconfirmedUploads[account] = UploadState(
            id: uploadID, sessionEpoch: sessionEpoch, vaultID: vaultID, editDates: dates
        )
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
                    editDates: dates,
                    legacyAppliedRevision: legacyAppliedRevision,
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

    func checkForChanges(
        endpoint: URL, deviceID: UUID, compareInitialImport: Bool = true
    ) async throws -> CheckResult {
        let sessionEpoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        let session: SelectiveRemoteCloudSessionBinding
        do {
            session = try await client.sessionBinding(endpoint: endpoint, expectedEpoch: sessionEpoch)
        } catch SelectiveRemoteCloudError.authenticationRequired {
            return sessionEpoch == SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
                ? .signedOut : .unavailable
        }
        guard let material = try keyStore.material(endpoint: endpoint, deviceID: deviceID)
        else { return .setupRequired }
        if !material.allowsUpload, !compareInitialImport { return .initialDownloadRequired(nil) }
        let remote = try await client.personalVault(endpoint: endpoint, session: session)
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
        if !material.allowsUpload {
            return .initialDownloadRequired(try makeDownload(remote, material: material, session: session))
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
        return .download(try makeDownload(remote, material: material, session: session))
    }

    private func makeDownload(
        _ remote: SelectiveRemoteCloudPersonalVault,
        material: SelectiveRemotePersonalVaultKeyMaterial,
        session: SelectiveRemoteCloudSessionBinding
    ) throws -> Download {
        let document = try openCurrent(remote, material: material)
        return Download(
            document: document,
            revision: remote.revision,
            documentHash: Data(SHA256.hash(data: try document.encoded())),
            sourceMaterial: material,
            session: session
        )
    }

    @MainActor
    func reportInitialImport(
        _ download: Download, deviceID: UUID, report: @MainActor () -> Void
    ) throws {
        try download.session.withCurrentPersonalVault(
            tokenStore: client.tokenStore, keyStore: keyStore, deviceID: deviceID,
            expected: download.sourceMaterial, perform: report
        )
    }

    @MainActor
    func acceptDownload(
        _ download: Download, endpoint: URL, deviceID: UUID,
        apply: @MainActor () throws -> Bool
    ) throws -> Bool {
        guard download.session.endpoint == endpoint,
              download.sourceMaterial.allowsUpload,
              download.revision > download.sourceMaterial.revision
        else { return false }
        var material = download.sourceMaterial
        material.revision = download.revision
        material.documentHash = download.documentHash
        material.requiresInitialDownload = false
        return try download.session.commitPersonalVault(
            tokenStore: client.tokenStore, keyStore: keyStore, deviceID: deviceID,
            expected: download.sourceMaterial, material: material, apply: apply
        )
    }

    private func synchronize(
        endpoint: URL,
        deviceID: UUID,
        profiles: [ConnectionProfile],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        sshKeys: [SSHKeyRecord],
        editDates: [UUID: Date],
        legacyAppliedRevision: Int?,
        uploadID: UUID,
        sessionEpoch: UUID
    ) async throws -> UploadResult {
        guard let material = try keyStore.material(endpoint: endpoint, deviceID: deviceID),
              await client.hasStoredSession(endpoint: endpoint)
        else { return .unavailable }
        let recovering = !material.allowsUpload
        guard let baseRevision = recovering ? legacyAppliedRevision : material.revision,
              baseRevision > 0,
              !recovering || baseRevision < material.revision
        else { return .unavailable }

        let account = Account(endpoint: endpoint, deviceID: deviceID)
        let session = try await client.sessionBinding(endpoint: endpoint, expectedEpoch: sessionEpoch)
        try requireCurrentUpload(material, account: account, id: uploadID, epoch: sessionEpoch)
        var remote = try await client.personalVault(endpoint: endpoint, session: session)
        try requireCurrentUpload(material, account: account, id: uploadID, epoch: sessionEpoch)
        var current = try openCurrent(remote, material: material)
        let base: SelectiveRemoteVaultDocument
        if baseRevision == remote.revision {
            base = current
        } else {
            guard let historical = try await client.personalVaultRevision(
                endpoint: endpoint, revision: baseRevision, writtenByThisDevice: recovering, session: session
            ) else {
                if recovering { return .unavailable }
                throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
            }
            try requireCurrentUpload(material, account: account, id: uploadID, epoch: sessionEpoch)
            guard historical.id == material.vaultID, historical.revision == baseRevision,
                  let envelope = historical.envelope, envelope.wrappedKey == material.wrappedKey
            else { throw SelectiveRemotePersonalVaultError.invalidEnvelope }
            base = try SelectiveRemotePersonalVaultCrypto.open(envelope, vaultKey: material.vaultKey)
        }
        let baseHash = Data(SHA256.hash(data: try base.encoded()))
        guard recovering || baseHash == material.documentHash else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: profiles,
            credentials: try await SelectiveRemotePersonalVaultCredentialCollector.shared.collect(
                profiles: profiles, forwarding: forwarding
            ),
            snippets: snippets,
            forwarding: forwarding,
            sshKeys: try await SelectiveRemotePersonalVaultCredentialCollector.shared.collectSSHKeys(sshKeys),
            deviceID: deviceID,
            allowEmpty: true
        )
        let observedEdits = editDates.mapValues(SelectiveRemotePersonalVaultExporter.timestamp)
        for attempt in 0..<3 {
            try requireCurrentUpload(material, account: account, id: uploadID, epoch: sessionEpoch)
            let document = try SelectiveRemotePersonalVaultReconciliation.reconcile(
                local: exported.document, base: base, current: current, deviceID: deviceID, editDates: observedEdits
            )
            var committedRevision = remote.revision
            if document != current {
                let envelope = try SelectiveRemotePersonalVaultCrypto.reseal(
                    document, vaultKey: material.vaultKey, wrappedKey: material.wrappedKey,
                    baseRevision: remote.revision
                )
                let result = try await client.putPersonalVault(endpoint: endpoint, envelope: envelope, session: session)
                try requireCurrentUpload(material, account: account, id: uploadID, epoch: sessionEpoch)
                if result.conflict, attempt < 2 {
                    remote = try await client.personalVault(endpoint: endpoint, session: session)
                    current = try openCurrent(remote, material: material)
                    continue
                }
                guard !result.conflict, result.revision == remote.revision + 1 else {
                    throw SelectiveRemotePersonalVaultError.uploadConflict(result.revision)
                }
                committedRevision = result.revision
            }
            if recovering {
                // Enable inbound sync from the verified historical checkpoint;
                // it advances to the merged revision only after local application.
                var recovered = material
                recovered.requiresInitialDownload = false
                recovered.revision = baseRevision
                recovered.documentHash = baseHash
                try await client.savePersonalVaultMaterial(
                    recovered, session: session, deviceID: deviceID, keyStore: keyStore, replacing: material
                )
            } else if remote.revision == baseRevision, committedRevision > baseRevision {
                var applied = material
                applied.revision = committedRevision
                applied.documentHash = Data(SHA256.hash(data: try document.encoded()))
                try await client.savePersonalVaultMaterial(
                    applied, session: session, deviceID: deviceID, keyStore: keyStore, replacing: material
                )
                return .acknowledged(newAppliedMaterial: applied)
            }
            return .acknowledged(newAppliedMaterial: nil)
        }
        throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
    }

    private func openCurrent(
        _ remote: SelectiveRemoteCloudPersonalVault, material: SelectiveRemotePersonalVaultKeyMaterial
    ) throws -> SelectiveRemoteVaultDocument {
        guard remote.id == material.vaultID, remote.revision >= material.revision else {
            throw SelectiveRemotePersonalVaultError.uploadConflict(remote.revision)
        }
        guard let envelope = remote.envelope, envelope.wrappedKey == material.wrappedKey else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        return try SelectiveRemotePersonalVaultCrypto.open(envelope, vaultKey: material.vaultKey)
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
}
