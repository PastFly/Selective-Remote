import CryptoKit
import Foundation

enum SelectiveRemotePersonalVaultConflictResolution {
    enum Failure: LocalizedError, Equatable {
        case staleReview
        case invalidRecord
        case confirmationFailed

        var errorDescription: String? {
            switch self {
            case .staleReview:
                UpdateLocalization.text(
                    ru: "Записи изменились. Проверьте обновлённый список и выберите версии снова.",
                    en: "Records changed. Review the updated list and choose the versions again."
                )
            case .invalidRecord:
                UpdateLocalization.text(
                    ru: "Не удалось подготовить полную копию записи. Синхронизация приостановлена.",
                    en: "A complete copy of a record could not be prepared. Sync remains paused."
                )
            case .confirmationFailed:
                UpdateLocalization.text(
                    ru: "Cloud ещё не подтвердил выбранные версии. Сохранённые копии доступны.",
                    en: "Cloud has not confirmed the selected versions yet. The saved copies are available."
                )
            }
        }
    }

    struct Plan {
        let document: SelectiveRemoteVaultDocument
        let macBackup: SelectiveRemoteVaultDocument
        let cloudBackup: SelectiveRemoteVaultDocument
    }

    static func subset(
        of document: SelectiveRemoteVaultDocument, for ids: Set<UUID>
    ) throws -> SelectiveRemoteVaultDocument {
        let credentialIDs = Set(ids.flatMap { id in
            KeychainCredentialKind.allCases.filter { $0 != .sshKeyAuthorization }.map {
                SelectiveRemotePersonalVaultExporter.derivedID(sourceID: id, discriminator: "credential:\($0.rawValue)")
            }
        })
        return try .init(
            records: document.records.filter { ids.contains($0.id) || sourceID($0).map(ids.contains) == true },
            tombstones: document.tombstones.filter { ids.contains($0.id) || credentialIDs.contains($0.id) }
        )
    }

    static func plan(
        local: SelectiveRemoteVaultDocument,
        remote: SelectiveRemoteVaultDocument,
        conflictIDs: Set<UUID>,
        choices: [UUID: SelectiveRemoteVaultConflictChoice],
        deviceID: UUID,
        resolvedAt: String
    ) throws -> Plan {
        guard !conflictIDs.isEmpty, Set(choices.keys) == conflictIDs else { throw Failure.staleReview }
        let macBackup = try subset(of: local, for: conflictIDs)
        let cloudBackup = try subset(of: remote, for: conflictIDs)
        let localByID = Dictionary(uniqueKeysWithValues: macBackup.records.map { ($0.id, $0) })
        var records = Dictionary(uniqueKeysWithValues: remote.records.map { ($0.id, $0) })
        var tombstones = Dictionary(uniqueKeysWithValues: remote.tombstones.map { ($0.id, $0) })
        for (id, choice) in choices {
            guard let mac = localByID[id], mac.type != .credential else { throw Failure.invalidRecord }
            let cloud = records[id]
            if let cloud, cloud.type != mac.type { throw Failure.invalidRecord }
            let macCredentials = try credentials(in: macBackup, source: id)
            let cloudCredentials = try credentials(in: cloudBackup, source: id)
            guard choice == .local else { continue }
            let deletion = tombstones.removeValue(forKey: id)
            if mac.data != cloud?.data {
                let data = SelectiveRemoteVaultBrowserMetadata.preservingFavorite(in: mac.data, from: cloud)
                records[id] = try replacement(
                    mac, id: id, data: data, previous: cloud, deletion: deletion,
                    deviceID: deviceID, resolvedAt: resolvedAt
                )
            }
            for kind in Set(macCredentials.keys).union(cloudCredentials.keys) {
                let current = cloudCredentials[kind]
                if let next = macCredentials[kind] {
                    let credentialID = current?.id ?? next.id
                    guard records[credentialID] == current else { throw Failure.invalidRecord }
                    guard current?.data != next.data else { continue }
                    records[credentialID] = try replacement(
                        next, id: credentialID, data: next.data, previous: current,
                        deletion: tombstones.removeValue(forKey: credentialID),
                        deviceID: deviceID, resolvedAt: resolvedAt
                    )
                } else if let current {
                    records.removeValue(forKey: current.id)
                    tombstones[current.id] = try .init(
                        id: current.id, version: current.version.incrementing(deviceID),
                        deletedAt: max(resolvedAt, current.modifiedAt)
                    )
                }
            }
        }
        return Plan(
            document: try .init(records: Array(records.values), tombstones: Array(tombstones.values)),
            macBackup: macBackup, cloudBackup: cloudBackup
        )
    }

    private static func sourceID(_ record: SelectiveRemoteVaultRecord) -> UUID? {
        guard record.type == .credential, case let .object(data) = record.data,
              case let .string(source)? = data["sourceID"] else { return nil }
        return UUID(uuidString: source)
    }

    private static func credentials(
        in document: SelectiveRemoteVaultDocument, source id: UUID
    ) throws -> [String: SelectiveRemoteVaultRecord] {
        var result: [String: SelectiveRemoteVaultRecord] = [:]
        for record in document.records where sourceID(record) == id {
            guard case let .object(data) = record.data, case let .string(kind)? = data["kind"],
                  result.updateValue(record, forKey: kind) == nil else { throw Failure.invalidRecord }
        }
        return result
    }

    private static func replacement(
        _ local: SelectiveRemoteVaultRecord, id: UUID, data: SelectiveRemoteJSONValue,
        previous: SelectiveRemoteVaultRecord?, deletion: SelectiveRemoteVaultTombstone?,
        deviceID: UUID, resolvedAt: String
    ) throws -> SelectiveRemoteVaultRecord {
        let previousVersion = previous?.version ?? deletion?.version
        let version = try previousVersion.map { try $0.joined(with: local.version, incrementing: deviceID) }
            ?? local.version
        return try .init(id: id, type: local.type, version: version,
                         modifiedAt: max(resolvedAt, previous?.modifiedAt ?? deletion?.deletedAt ?? ""), data: data)
    }
}

struct SelectiveRemotePersonalVaultConflictReview {
    let remote: SelectiveRemoteCloudPersonalVault
    let local: SelectiveRemoteVaultDocument
    let cloud: SelectiveRemoteVaultDocument
    let material: SelectiveRemotePersonalVaultKeyMaterial
    let differences: [PersonalVaultImportDifference]

    var ids: Set<UUID> { Set(differences.map(\.id)) }

    func matches(_ other: Self) -> Bool {
        remote == other.remote && local == other.local && material == other.material && ids == other.ids
    }

    static func summary(_ id: UUID, in document: SelectiveRemoteVaultDocument) -> [String] {
        if document.tombstones.contains(where: { $0.id == id }) {
            return [UpdateLocalization.text(ru: "Запись удалена", en: "Record deleted")]
        }
        guard let record = document.records.first(where: { $0.id == id }),
              case let .object(fields) = record.data else {
            return [UpdateLocalization.text(ru: "Записи нет", en: "Record absent")]
        }
        let values = ["title", "address", "username", "destination"].compactMap { field -> String? in
            guard case let .string(value)? = fields[field], !value.isEmpty else { return nil }
            return value
        }
        // Sensitive values stay in the encrypted document. A truncated key
        // reference is sufficient to distinguish the selected SSH identities.
        if case let .string(profile)? = fields["profile"],
           let bytes = Data(selectiveRemoteBase64URL: profile),
           let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let keyID = object["sshIdentityID"] as? String, UUID(uuidString: keyID) != nil {
            let reference = String(keyID.prefix(8))
            return values + [UpdateLocalization.text(ru: "SSH-ключ \(reference)", en: "SSH key \(reference)")]
        }
        return values
    }

    @MainActor
    static func captureLocal(
        ids: Set<UUID>, model: AppModel, deviceID: UUID
    ) async throws -> SelectiveRemoteVaultDocument {
        let profiles = model.profiles.filter { ids.contains($0.id) }
        let forwarding = model.independentPortForwards.filter { ids.contains($0.id) }
        let keys = model.sshKeys.filter { ids.contains($0.id) }
        let history = TerminalCommandHistoryStore.shared
        let snippets = history.templates().filter { ids.contains($0.id) }
        let credentialSources = profiles.map { ($0.id, $0.friendlyName, $0.username) }
            + forwarding.map { ($0.id, $0.rule.displayName, $0.connection.username) }
        let credentials = try await Task.detached {
            try credentialSources.flatMap { id, title, username in
                try KeychainCredentialKind.allCases.compactMap { kind -> SelectiveRemotePersonalVaultCredentialInput? in
                    guard kind != .sshKeyAuthorization else { return nil }
                    let primary = KeychainService.credentialReference(profileID: id, kind: kind)
                    var secret = try KeychainService.readPassword(reference: primary)
                    if secret == nil, kind == .ssh || kind == .forwarding {
                        let legacy = KeychainCredentialReference(
                            service: KeychainService.legacyService, account: kind.account(profileID: id), kind: kind
                        )
                        secret = try KeychainService.readPassword(reference: legacy)
                    }
                    guard let secret, !secret.isEmpty else { return nil }
                    return .init(sourceID: id, kind: kind, title: title, username: username, secret: secret)
                }
            }
        }.value
        let keyFiles = try await SelectiveRemotePersonalVaultCredentialCollector.shared.collectSSHKeys(keys)
        guard profiles == model.profiles.filter({ ids.contains($0.id) }),
              forwarding == model.independentPortForwards.filter({ ids.contains($0.id) }),
              keys == model.sshKeys.filter({ ids.contains($0.id) }),
              snippets == history.templates().filter({ ids.contains($0.id) }) else {
            throw SelectiveRemotePersonalVaultConflictResolution.Failure.staleReview
        }
        return try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: profiles, credentials: credentials, snippets: snippets, forwarding: forwarding,
            sshKeys: keyFiles, deviceID: deviceID, now: Date(timeIntervalSince1970: 0), allowEmpty: true
        ).document
    }
}

struct SelectiveRemotePersonalVaultConflictCopies: Codable {
    let formatVersion: Int
    let createdAt: Date
    let mac: SelectiveRemotePersonalVaultEnvelope
    let cloud: SelectiveRemotePersonalVaultEnvelope

    static func folder() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("Selective Remote", isDirectory: true)
            .appendingPathComponent("Personal Vault Conflict Copies", isDirectory: true)
    }

    static func save(
        _ plan: SelectiveRemotePersonalVaultConflictResolution.Plan,
        material: SelectiveRemotePersonalVaultKeyMaterial, revision: Int, in directory: URL? = nil
    ) throws -> URL {
        let root = try directory ?? folder()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fingerprint = try Data(SHA256.hash(data: plan.macBackup.encoded()))
            + Data(SHA256.hash(data: plan.cloudBackup.encoded()))
            + Data("\(material.vaultID.canonicalCloudString):\(revision)".utf8)
        let digest = HMAC<SHA256>.authenticationCode(for: fingerprint, using: SymmetricKey(data: material.vaultKey))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent(name).appendingPathExtension("srvaultcopies")
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard saved.formatVersion == 1,
                  try SelectiveRemotePersonalVaultCrypto.open(saved.mac, vaultKey: material.vaultKey) == plan.macBackup,
                  try SelectiveRemotePersonalVaultCrypto.open(saved.cloud, vaultKey: material.vaultKey) == plan.cloudBackup
            else { throw SelectiveRemotePersonalVaultConflictResolution.Failure.invalidRecord }
            return url
        }
        let copies = try Self(
            formatVersion: 1, createdAt: Date(),
            mac: SelectiveRemotePersonalVaultCrypto.reseal(
                plan.macBackup, vaultKey: material.vaultKey, wrappedKey: material.wrappedKey, baseRevision: revision
            ),
            cloud: SelectiveRemotePersonalVaultCrypto.reseal(
                plan.cloudBackup, vaultKey: material.vaultKey, wrappedKey: material.wrappedKey, baseRevision: revision
            )
        )
        try JSONEncoder().encode(copies).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
