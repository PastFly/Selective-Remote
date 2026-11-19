import Foundation

enum SelectiveRemotePersonalVaultReconciliation {
    static func reconcile(
        local: SelectiveRemoteVaultDocument,
        base: SelectiveRemoteVaultDocument,
        current: SelectiveRemoteVaultDocument,
        deviceID: UUID,
        editDates: [UUID: String]
    ) throws -> SelectiveRemoteVaultDocument {
        // Compare against a native projection of the base. Web-only fields and
        // standalone credentials stay in Cloud when the Mac doesn't edit them.
        let baseSnapshot = try SelectiveRemotePersonalVaultImporter.decode(base)
        let projectedBase = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: baseSnapshot.profiles, credentials: baseSnapshot.credentials,
            snippets: baseSnapshot.snippets, forwarding: baseSnapshot.forwarding,
            sshKeys: baseSnapshot.sshKeys, deviceID: deviceID, allowEmpty: true
        ).document
        let before = Dictionary(uniqueKeysWithValues: projectedBase.records.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: local.records.map { ($0.id, $0) })
        let baseRecords = Dictionary(uniqueKeysWithValues: base.records.map { ($0.id, $0) })
        let baseTombstones = Dictionary(uniqueKeysWithValues: base.tombstones.map { ($0.id, $0) })
        var records = Dictionary(uniqueKeysWithValues: current.records.map { ($0.id, $0) })
        var tombstones = Dictionary(uniqueKeysWithValues: current.tombstones.map { ($0.id, $0) })
        let now = SelectiveRemotePersonalVaultExporter.timestamp(Date())
        for id in Set(before.keys).union(after.keys) {
            let changed = after[id]
            if try equivalent(before[id], changed) { continue }
            let editedAt = editDates[id]
            let existing = records[id]
            let deleted = tombstones[id]
            if let changed, existing != nil, try equivalent(changed, existing) { continue }
            if changed == nil, existing == nil { continue }
            let remoteTimestamp = existing?.modifiedAt ?? deleted?.deletedAt
            let cloudChanged = try !equivalent(baseRecords[id], existing) || (baseTombstones[id] == nil) != (deleted == nil)
            if base != current, cloudChanged, let remoteTimestamp {
                // An offline snapshot with no observed edit time can't establish
                // the order of two incompatible edits to the same record.
                guard let editedAt else { throw SelectiveRemotePersonalVaultImportError.conflicts([id]) }
                if editedAt <= remoteTimestamp { continue }
            }

            let previous = existing?.version ?? deleted?.version
            let version = try previous?.incrementing(deviceID) ?? SelectiveRemoteVaultVersion([deviceID: 1])
            let timestamp = max(editedAt ?? now, remoteTimestamp ?? "")
            if let changed {
                records[id] = try .init(
                    id: id, type: changed.type, version: version, modifiedAt: timestamp,
                    data: SelectiveRemoteVaultBrowserMetadata.preservingFavorite(in: changed.data, from: existing)
                )
                tombstones.removeValue(forKey: id)
            } else {
                records.removeValue(forKey: id)
                tombstones[id] = try .init(id: id, version: version, deletedAt: timestamp)
            }
        }
        return try .init(records: Array(records.values), tombstones: Array(tombstones.values))
    }

    private static func equivalent(
        _ left: SelectiveRemoteVaultRecord?, _ right: SelectiveRemoteVaultRecord?
    ) throws -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        guard left.type == right.type else { return false }
        return try comparableData(left) == comparableData(right)
    }

    private static func comparableData(_ record: SelectiveRemoteVaultRecord) throws -> SelectiveRemoteJSONValue {
        guard case var .object(data) = record.data else { return record.data }
        data.removeValue(forKey: "favorite")
        switch record.type {
        case .host:
            try normalize(&data, field: "profile", dropping: ["lastConnectedAt"])
        case .sshKey:
            try normalize(&data, field: "record", dropping: ["privateKeyPath", "publicKeyPath"])
        case .credential:
            data.removeValue(forKey: "title")
            data.removeValue(forKey: "username")
        case .snippet, .forwarding:
            break
        }
        return .object(data)
    }

    private static func normalize(
        _ data: inout [String: SelectiveRemoteJSONValue], field: String, dropping keys: [String]
    ) throws {
        guard case let .string(text)? = data[field],
              let bytes = Data(selectiveRemoteBase64URL: text),
              let value = try JSONDecoder().decode(SelectiveRemoteJSONValue?.self, from: bytes),
              case var .object(object) = value
        else { return }
        for key in keys { object.removeValue(forKey: key) }
        if case let .array(displays)? = object["selectedDisplayIDs"] {
            let names = displays.compactMap { display -> String? in
                guard case let .string(name) = display else { return nil }
                return name
            }
            if names.count == displays.count {
                object["selectedDisplayIDs"] = .array(names.sorted().map(SelectiveRemoteJSONValue.string))
            }
        }
        data[field] = .object(object)
    }
}
