import Foundation

enum SelectiveRemotePersonalVaultImportError: LocalizedError, Equatable {
    case invalidRecord(UUID)
    case mismatchedRecordID(UUID)
    case unsupportedWebForwarding(UUID)
    case conflicts([UUID])

    var errorDescription: String? {
        switch self {
        case let .conflicts(ids):
            UpdateLocalization.text(
                ru: "Initial download остановлен: локальные и Cloud-данные конфликтуют (\(ids.count)). Ничего не перезаписано.",
                en: "Initial download stopped because local and Cloud data conflict (\(ids.count)). Nothing was overwritten."
            )
        case .unsupportedWebForwarding:
            UpdateLocalization.text(
                ru: "Forwarding с сайта не содержит полной конфигурации и не был применён.",
                en: "A web Forwarding record has no complete configuration and was not applied."
            )
        case .invalidRecord, .mismatchedRecordID:
            UpdateLocalization.text(
                ru: "Personal Vault содержит некорректную запись; импорт остановлен.",
                en: "Personal Vault contains an invalid record; import was stopped."
            )
        }
    }
}

struct SelectiveRemotePersonalVaultImportSnapshot: Equatable {
    let profiles: [ConnectionProfile]
    let credentials: [SelectiveRemotePersonalVaultCredentialInput]
    let snippets: [TerminalCommandTemplate]
    let forwarding: [IndependentPortForward]
    let sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput]
    let tombstoneIDs: Set<UUID>

    init(
        profiles: [ConnectionProfile],
        credentials: [SelectiveRemotePersonalVaultCredentialInput],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput] = [],
        tombstoneIDs: Set<UUID>
    ) {
        self.profiles = profiles
        self.credentials = credentials
        self.snippets = snippets
        self.forwarding = forwarding
        self.sshKeys = sshKeys
        self.tombstoneIDs = tombstoneIDs
    }
}

struct SelectiveRemotePersonalVaultImportPlan: Equatable {
    let profiles: [ConnectionProfile]
    let credentials: [SelectiveRemotePersonalVaultCredentialInput]
    let snippets: [TerminalCommandTemplate]
    let forwarding: [IndependentPortForward]
    let sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput]
    let conflictIDs: [UUID]

    var canApply: Bool { conflictIDs.isEmpty }
}

enum SelectiveRemotePersonalVaultImporter {
    private static let globalSnippetLibraryID = UUID(
        uuidString: "5A17407D-9F03-4F7B-80FB-BD06D3FA50B1"
    )!

    static func decode(_ document: SelectiveRemoteVaultDocument) throws
        -> SelectiveRemotePersonalVaultImportSnapshot
    {
        var profiles: [ConnectionProfile] = []
        var credentials: [SelectiveRemotePersonalVaultCredentialInput] = []
        var snippets: [TerminalCommandTemplate] = []
        var forwarding: [IndependentPortForward] = []
        var sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput] = []
        for record in document.records {
            guard case let .object(data) = record.data else {
                throw SelectiveRemotePersonalVaultImportError.invalidRecord(record.id)
            }
            switch record.type {
            case .host:
                profiles.append(try profile(record: record, data: data))
            case .credential:
                credentials.append(try credential(record: record, data: data))
            case .snippet:
                snippets.append(try snippet(record: record, data: data))
            case .forwarding:
                forwarding.append(try forward(record: record, data: data))
            case .sshKey:
                sshKeys.append(try sshKey(record: record, data: data))
            }
        }
        return .init(
            profiles: profiles,
            credentials: credentials,
            snippets: snippets,
            forwarding: forwarding,
            sshKeys: sshKeys,
            tombstoneIDs: Set(document.tombstones.map(\.id))
        )
    }

    static func plan(
        snapshot: SelectiveRemotePersonalVaultImportSnapshot,
        localProfiles: [ConnectionProfile],
        localSnippets: [TerminalCommandTemplate],
        localForwarding: [IndependentPortForward],
        localSSHKeys: [SSHKeyRecord] = []
    ) -> SelectiveRemotePersonalVaultImportPlan {
        let profiles = additions(remote: snapshot.profiles, local: localProfiles)
        let snippets = additions(remote: snapshot.snippets, local: localSnippets)
        let forwarding = additions(remote: snapshot.forwarding, local: localForwarding)
        let localSSHByID = Dictionary(uniqueKeysWithValues: localSSHKeys.map { ($0.id, $0) })
        var sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput] = []
        var sshKeyConflicts: [UUID] = []
        for key in snapshot.sshKeys {
            if let local = localSSHByID[key.record.id] {
                if local.fingerprint != key.record.fingerprint { sshKeyConflicts.append(key.record.id) }
            } else {
                sshKeys.append(key)
            }
        }
        var conflicts = Set(profiles.conflicts + snippets.conflicts + forwarding.conflicts)
        conflicts.formUnion(sshKeyConflicts)
        let localIDs = Set(localProfiles.map(\.id) + localSnippets.map(\.id) + localForwarding.map(\.id))
        conflicts.formUnion(snapshot.tombstoneIDs.intersection(localIDs))
        let existingProfileIDs = Set(localProfiles.map(\.id))
        conflicts.formUnion(snapshot.credentials.lazy.map(\.sourceID).filter(existingProfileIDs.contains))
        return .init(
            profiles: profiles.values,
            credentials: snapshot.credentials.filter { !conflicts.contains($0.sourceID) },
            snippets: snippets.values,
            forwarding: forwarding.values,
            sshKeys: sshKeys,
            conflictIDs: conflicts.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private static func additions<T: Identifiable & Equatable>(remote: [T], local: [T])
        -> (values: [T], conflicts: [UUID]) where T.ID == UUID
    {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var values: [T] = []
        var conflicts: [UUID] = []
        for value in remote {
            if let existing = localByID[value.id] {
                if existing != value { conflicts.append(value.id) }
            } else {
                values.append(value)
            }
        }
        return (values, conflicts)
    }

    private static func profile(
        record: SelectiveRemoteVaultRecord,
        data: [String: SelectiveRemoteJSONValue]
    ) throws -> ConnectionProfile {
        if let encoded = string(data["profile"]) {
            let value: ConnectionProfile = try decode(encoded, recordID: record.id)
            guard value.id == record.id else {
                throw SelectiveRemotePersonalVaultImportError.mismatchedRecordID(record.id)
            }
            return value
        }
        guard let address = string(data["address"]), !address.isEmpty else {
            throw SelectiveRemotePersonalVaultImportError.invalidRecord(record.id)
        }
        let type = string(data["connectionType"]).flatMap(ConnectionType.init(rawValue:)) ?? .ssh
        var value = ConnectionProfile(connectionType: type)
        value.id = record.id
        value.friendlyName = string(data["title"]) ?? address
        value.username = string(data["username"]) ?? ""
        value.group = SelectiveRemoteHostFolderPath.normalize(string(data["folder"]) ?? "")
        value.profileDescription = String((string(data["description"]) ?? "").prefix(2_048))
        if case let .array(tagValues)? = data["tags"] {
            value.tags = Array(tagValues.compactMap(string).prefix(24))
        }
        if (type == .ssh || type == .telnet), let port = integer(data["port"]),
           (1 ... 65_535).contains(port) {
            value.sshPort = port
        }
        if type == .serial { value.serialDevicePath = address } else { value.host = address }
        return value
    }

    private static func credential(
        record: SelectiveRemoteVaultRecord,
        data: [String: SelectiveRemoteJSONValue]
    ) throws -> SelectiveRemotePersonalVaultCredentialInput {
        guard let source = string(data["sourceID"]), let sourceID = UUID(uuidString: source),
              let kindText = string(data["kind"]), let kind = KeychainCredentialKind(rawValue: kindText),
              kind != .sshKeyAuthorization,
              let secret = string(data["secret"]), !secret.isEmpty
        else { throw SelectiveRemotePersonalVaultImportError.invalidRecord(record.id) }
        return .init(
            sourceID: sourceID,
            kind: kind,
            title: string(data["title"]) ?? kindText,
            username: string(data["username"]) ?? "",
            secret: secret
        )
    }

    private static func snippet(
        record: SelectiveRemoteVaultRecord,
        data: [String: SelectiveRemoteJSONValue]
    ) throws -> TerminalCommandTemplate {
        if let encoded = string(data["template"]) {
            let value: TerminalCommandTemplate = try decode(encoded, recordID: record.id)
            guard value.id == record.id else {
                throw SelectiveRemotePersonalVaultImportError.mismatchedRecordID(record.id)
            }
            return value
        }
        guard let body = string(data["body"]), !body.isEmpty else {
            throw SelectiveRemotePersonalVaultImportError.invalidRecord(record.id)
        }
        return .init(
            id: record.id,
            profileID: globalSnippetLibraryID,
            title: string(data["title"]) ?? "Snippet",
            command: body,
            category: string(data["category"]) ?? "",
            targets: [.localTerminal],
            isExplicitlyUngrouped: true,
            updatedAt: ISO8601DateFormatter().date(from: record.modifiedAt) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private static func forward(
        record: SelectiveRemoteVaultRecord,
        data: [String: SelectiveRemoteJSONValue]
    ) throws -> IndependentPortForward {
        guard let encoded = string(data["configuration"]) else {
            throw SelectiveRemotePersonalVaultImportError.unsupportedWebForwarding(record.id)
        }
        let value: IndependentPortForward = try decode(encoded, recordID: record.id)
        guard value.id == record.id, value.rule.id == record.id else {
            throw SelectiveRemotePersonalVaultImportError.mismatchedRecordID(record.id)
        }
        return value
    }

    private static func sshKey(
        record: SelectiveRemoteVaultRecord,
        data: [String: SelectiveRemoteJSONValue]
    ) throws -> SelectiveRemotePersonalVaultSSHKeyInput {
        guard let encodedRecord = string(data["record"]),
              let privateText = string(data["privateKey"]),
              let privateKey = Data(selectiveRemoteBase64URL: privateText),
              !privateKey.isEmpty, privateKey.count <= 1_048_576
        else { throw SelectiveRemotePersonalVaultImportError.invalidRecord(record.id) }
        let key: SSHKeyRecord = try decode(encodedRecord, recordID: record.id)
        guard key.id == record.id else {
            throw SelectiveRemotePersonalVaultImportError.mismatchedRecordID(record.id)
        }
        func optionalData(_ name: String) throws -> Data? {
            guard let value = data[name] else { return nil }
            if case .null = value { return nil }
            guard let text = string(value), let decoded = Data(selectiveRemoteBase64URL: text),
                  decoded.count <= 1_048_576 else {
                throw SelectiveRemotePersonalVaultImportError.invalidRecord(record.id)
            }
            return decoded
        }
        return try .init(
            record: key,
            privateKey: privateKey,
            publicKey: optionalData("publicKey"),
            certificate: optionalData("certificate")
        )
    }

    private static func string(_ value: SelectiveRemoteJSONValue?) -> String? {
        guard case let .string(result)? = value else { return nil }
        return result
    }

    private static func integer(_ value: SelectiveRemoteJSONValue?) -> Int? {
        guard case let .number(result)? = value, result.rounded() == result,
              result >= Double(Int.min), result <= Double(Int.max)
        else { return nil }
        return Int(result)
    }

    private static func decode<T: Decodable>(_ value: String, recordID: UUID) throws -> T {
        guard let data = Data(selectiveRemoteBase64URL: value) else {
            throw SelectiveRemotePersonalVaultImportError.invalidRecord(recordID)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) }
        catch { throw SelectiveRemotePersonalVaultImportError.invalidRecord(recordID) }
    }
}
