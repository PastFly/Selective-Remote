import Foundation

enum SelectiveRemoteLegacyMappingError: Error, Equatable {
    case invalidDocument, unsupportedRecord, embeddedSecret, opaqueProfile, invalidFolder
    case duplicateSourceID, tombstonedSourceID, scope, collision, limit
}
struct SelectiveRemoteLegacyMappedResource: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let parentFolderID: String?
    let sourceOrdinal: Int
}
struct SelectiveRemoteLegacyResourceMapping: Codable, Equatable, Sendable {
    struct Scope: Codable, Equatable, Sendable { let teamID: String; let vaultID: String }
    let version: Int
    let scope: Scope
    let mapping: [String: String]
    let resources: [SelectiveRemoteLegacyMappedResource]
}

enum SelectiveRemoteLegacyResourceMapper {
    private struct Entry { let key: String; let kind: String; let parent: String?; let ordinal: Int; let originalID: String? }
    private static let kinds = ["host": "HOST", "credential": "CREDENTIAL", "snippet": "SNIPPET", "forwarding": "FORWARDING"]
    private static func key(_ type: String, _ path: String) -> String {
        // ASCII keys preserve byte-distinct Unicode paths despite Swift's canonical String equality.
        "folder:" + type + ":" + Data(path.utf8).selectiveRemoteBase64URL
    }
    static func folderComponents(_ path: String) throws -> [String] {
        let parts = path.components(separatedBy: "/")
        guard !path.isEmpty, parts.count <= 32, parts.allSatisfy({ part in
            !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && part != "." && part != ".."
            && !part.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }) else { throw SelectiveRemoteLegacyMappingError.invalidFolder }
        return parts
    }
    private static func secret(_ value: SelectiveRemoteJSONValue) -> Bool {
        switch value {
        case let .object(o): return o.contains { name, item in
            let k = name.lowercased(), named = ["password", "secret", "privatekey", "passphrase", "token"].contains { k.contains($0) }
            return (named && item != .null && item != .string("") && item != .boolean(false)) || secret(item)
        }
        case let .array(a): return a.contains(where: secret)
        default: return false
        }
    }
    static func map(_ document: SelectiveRemoteJSONValue, teamID: UUID, vaultID: UUID,
                    previous: SelectiveRemoteLegacyResourceMapping? = nil,
                    reservedIDs: Set<String> = []) throws -> SelectiveRemoteLegacyResourceMapping {
        let d = try document.publicationObject()
        guard d["schemaVersion"] == .number(1), let rawRecords = d["records"], let rawTombstones = d["tombstones"],
              teamID.isSelectiveRemoteCloudUUID, vaultID.isSelectiveRemoteCloudUUID else { throw SelectiveRemoteLegacyMappingError.invalidDocument }
        let records = try rawRecords.publicationArray(), tombstones = try rawTombstones.publicationArray()
        guard records.count <= 1000 else { throw SelectiveRemoteLegacyMappingError.limit }
        let scope = SelectiveRemoteLegacyResourceMapping.Scope(teamID: teamID.canonicalCloudString, vaultID: vaultID.canonicalCloudString)
        if let previous { guard previous.version == 2, previous.scope == scope else { throw SelectiveRemoteLegacyMappingError.scope } }
        var mapping = previous?.mapping ?? [:], seen = Set<String>(), occurrences: [String: Int] = [:]
        guard Set(mapping.values).count == mapping.count,
              mapping.values.allSatisfy({ UUID(uuidString: $0)?.canonicalCloudString == $0 }) else { throw SelectiveRemoteLegacyMappingError.collision }
        let deleted = Set(try tombstones.compactMap { try $0.publicationObject()["id"]?.publicationString().lowercased() })
        var entries: [Entry] = [], folders: [Entry] = [], folderKeys = Set<String>()
        for (ordinal, raw) in records.enumerated() {
            let r = try raw.publicationObject(), type = try r["type"]?.publicationString()
            guard let type, let kind = kinds[type], let value = r["data"] else { throw SelectiveRemoteLegacyMappingError.unsupportedRecord }
            let data = try value.publicationObject()
            let original = r["id"].flatMap { try? $0.publicationString() }, normalized = original?.lowercased()
            let valid = normalized.flatMap(UUID.init(uuidString:)).flatMap { $0.isSelectiveRemoteCloudUUID ? $0.canonicalCloudString : nil }
            if let valid {
                guard seen.insert(valid).inserted else { throw SelectiveRemoteLegacyMappingError.duplicateSourceID }
                guard !deleted.contains(valid) else { throw SelectiveRemoteLegacyMappingError.tombstonedSourceID }
                guard !reservedIDs.contains(valid) else { throw SelectiveRemoteLegacyMappingError.collision }
            }
            if type == "host" || type == "forwarding" {
                guard !secret(value) else { throw SelectiveRemoteLegacyMappingError.embeddedSecret }
                for field in ["profile", "configuration"] {
                    if let raw = data[field] {
                        guard let string = try? raw.publicationString(),
                              let parsed = try? JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: Data(string.utf8)),
                              (try? parsed.publicationObject()) != nil else { throw SelectiveRemoteLegacyMappingError.opaqueProfile }
                        guard !secret(parsed) else { throw SelectiveRemoteLegacyMappingError.embeddedSecret }
                    }
                }
            }
            var parent: String?
            if type == "host" || type == "snippet", let folder = data["folder"], folder != .string("") {
                guard let path = try? folder.publicationString() else { throw SelectiveRemoteLegacyMappingError.invalidFolder }
                let parts = try folderComponents(path)
                for n in 1...parts.count {
                    let pathKey = key(type, parts.prefix(n).joined(separator: "/"))
                    if folderKeys.insert(pathKey).inserted { folders.append(.init(key: pathKey, kind: "FOLDER", parent: parent,
                        ordinal: records.count + folders.count, originalID: nil)) }
                    parent = pathKey
                }
            }
            let invalidKey = type + ":" + Data(try SelectiveRemoteVaultPublicationV1.canonical(r["id"] ?? .null).utf8).selectiveRemoteBase64URL
            let occurrence = occurrences[invalidKey, default: 0]; occurrences[invalidKey] = occurrence + 1
            let sourceKey = valid.map { "record:" + type + ":" + $0 } ?? "record:" + type + ":invalid:" + String(invalidKey.dropFirst(type.count + 1)) + ":" + String(occurrence)
            entries.append(.init(key: sourceKey, kind: kind, parent: parent, ordinal: ordinal, originalID: valid))
        }
        guard entries.count + folders.count <= 1000 else { throw SelectiveRemoteLegacyMappingError.limit }
        for entry in folders + entries {
            if let selected = mapping[entry.key] {
                guard !reservedIDs.contains(selected) else { throw SelectiveRemoteLegacyMappingError.collision }
            } else {
                let selected = entry.originalID ?? UUID().canonicalCloudString
                guard !mapping.values.contains(selected), !reservedIDs.contains(selected) else { throw SelectiveRemoteLegacyMappingError.collision }
                mapping[entry.key] = selected
            }
        }
        let resources = (entries + folders).map { entry in
            SelectiveRemoteLegacyMappedResource(id: mapping[entry.key]!, kind: entry.kind,
                parentFolderID: entry.parent.flatMap { mapping[$0] }, sourceOrdinal: entry.ordinal)
        }
        return .init(version: 2, scope: scope, mapping: mapping, resources: resources)
    }
}
