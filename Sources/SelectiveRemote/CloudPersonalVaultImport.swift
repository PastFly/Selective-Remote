import Foundation

enum SelectiveRemotePersonalVaultImportError: Error, Equatable {
    case invalidRecord(UUID)
    case mismatchedRecordID(UUID)
    case unsupportedWebForwarding(UUID)
}

struct SelectiveRemotePersonalVaultImportSnapshot: Equatable {
    let profiles: [ConnectionProfile]
    let credentials: [SelectiveRemotePersonalVaultCredentialInput]
    let snippets: [TerminalCommandTemplate]
    let forwarding: [IndependentPortForward]
    let tombstoneIDs: Set<UUID>
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
            }
        }
        return .init(
            profiles: profiles,
            credentials: credentials,
            snippets: snippets,
            forwarding: forwarding,
            tombstoneIDs: Set(document.tombstones.map(\.id))
        )
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

    private static func string(_ value: SelectiveRemoteJSONValue?) -> String? {
        guard case let .string(result)? = value else { return nil }
        return result
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
