import Foundation

enum SelectiveRemoteVaultDocumentError: Error, Equatable {
    case invalidVaultDocument
    case invalidVaultSchemaVersion
    case vaultTooLarge
    case duplicateRecordID
    case invalidVaultRecord
    case invalidVaultTombstone
    case invalidRecordType
    case invalidRecordID
    case invalidRecordVersion
    case invalidModifiedAt
    case invalidDeletedAt
    case invalidRecordData
    case invalidVaultConflict
    case conflictRecordPresent
    case invalidDevice
    case incompleteConflictResolutions
    case duplicateConflictResolution
    case unknownConflictResolution
}

enum SelectiveRemoteVaultRecordType: String, Codable, CaseIterable, Sendable {
    case host
    case credential
    case snippet
    case forwarding
    case sshKey
}

enum SelectiveRemoteJSONValue: Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([SelectiveRemoteJSONValue])
    case object([String: SelectiveRemoteJSONValue])
}

extension SelectiveRemoteJSONValue: Codable {
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if values.decodeNil() {
            self = .null
        } else if let value = try? values.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? values.decode(Double.self) {
            guard value.isFinite else {
                throw SelectiveRemoteVaultDocumentError.invalidRecordData
            }
            self = .number(value)
        } else if let value = try? values.decode(String.self) {
            self = .string(value)
        } else if let value = try? values.decode([SelectiveRemoteJSONValue].self) {
            self = .array(value)
        } else if let value = try? values.decode([String: SelectiveRemoteJSONValue].self) {
            self = .object(value)
        } else {
            throw SelectiveRemoteVaultDocumentError.invalidRecordData
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.singleValueContainer()
        switch self {
        case .null:
            try values.encodeNil()
        case let .boolean(value):
            try values.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw SelectiveRemoteVaultDocumentError.invalidRecordData
            }
            try values.encode(value)
        case let .string(value):
            try values.encode(value)
        case let .array(value):
            try values.encode(value)
        case let .object(value):
            try values.encode(value)
        }
    }
}

struct SelectiveRemoteVaultVersion: Equatable, Sendable {
    static let maximumCounter = 9_007_199_254_740_991

    let counters: [UUID: Int]

    init(_ counters: [UUID: Int]) throws {
        guard !counters.isEmpty, counters.count <= 128,
              counters.values.allSatisfy({ (1 ... Self.maximumCounter).contains($0) })
        else { throw SelectiveRemoteVaultDocumentError.invalidRecordVersion }
        self.counters = counters
    }

    func incrementing(_ deviceID: UUID) throws -> Self {
        var result = counters
        let current = result[deviceID] ?? 0
        guard current < Self.maximumCounter else {
            throw SelectiveRemoteVaultDocumentError.invalidRecordVersion
        }
        result[deviceID] = current + 1
        return try .init(result)
    }

    func joined(with other: Self, incrementing deviceID: UUID) throws -> Self {
        var result = counters
        for (key, value) in other.counters {
            result[key] = max(result[key] ?? 0, value)
        }
        return try Self(result).incrementing(deviceID)
    }
}

extension SelectiveRemoteVaultVersion: Codable {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self)
        guard !values.allKeys.isEmpty, values.allKeys.count <= 128 else {
            throw SelectiveRemoteVaultDocumentError.invalidRecordVersion
        }
        var result: [UUID: Int] = [:]
        for key in values.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            let deviceID = try SelectiveRemoteVaultValidation.uuid(
                key.stringValue,
                error: .invalidRecordVersion
            )
            let counter = try values.decode(Int.self, forKey: key)
            guard (1 ... Self.maximumCounter).contains(counter) else {
                throw SelectiveRemoteVaultDocumentError.invalidRecordVersion
            }
            result[deviceID] = counter
        }
        try self.init(result)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self)
        for (deviceID, counter) in counters.sorted(by: {
            $0.key.canonicalCloudString < $1.key.canonicalCloudString
        }) {
            let key = SelectiveRemoteAnyCodingKey(stringValue: deviceID.canonicalCloudString)!
            try values.encode(counter, forKey: key)
        }
    }
}

struct SelectiveRemoteVaultRecord: Equatable, Sendable, Codable {
    let id: UUID
    let type: SelectiveRemoteVaultRecordType
    let version: SelectiveRemoteVaultVersion
    let modifiedAt: String
    let data: SelectiveRemoteJSONValue

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, type, version, modifiedAt, data
    }

    init(
        id: UUID,
        type: SelectiveRemoteVaultRecordType,
        version: SelectiveRemoteVaultVersion,
        modifiedAt: String,
        data: SelectiveRemoteJSONValue
    ) throws {
        try SelectiveRemoteVaultValidation.timestamp(modifiedAt, error: .invalidModifiedAt)
        self.id = id
        self.type = type
        self.version = version
        self.modifiedAt = modifiedAt
        self.data = data
    }

    init(from decoder: Decoder) throws {
        try SelectiveRemoteVaultValidation.exactKeys(
            decoder,
            expected: CodingKeys.allCases.map(\.rawValue),
            error: .invalidVaultRecord
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try values.decode(String.self, forKey: .id)
        guard let type = try? values.decode(SelectiveRemoteVaultRecordType.self, forKey: .type) else {
            throw SelectiveRemoteVaultDocumentError.invalidRecordType
        }
        try self.init(
            id: SelectiveRemoteVaultValidation.uuid(rawID, error: .invalidRecordID),
            type: type,
            version: values.decode(SelectiveRemoteVaultVersion.self, forKey: .version),
            modifiedAt: values.decode(String.self, forKey: .modifiedAt),
            data: values.decode(SelectiveRemoteJSONValue.self, forKey: .data)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.canonicalCloudString, forKey: .id)
        try values.encode(type, forKey: .type)
        try values.encode(version, forKey: .version)
        try values.encode(modifiedAt, forKey: .modifiedAt)
        try values.encode(data, forKey: .data)
    }
}

struct SelectiveRemoteVaultTombstone: Equatable, Sendable, Codable {
    let id: UUID
    let version: SelectiveRemoteVaultVersion
    let deletedAt: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, version, deletedAt
    }

    init(id: UUID, version: SelectiveRemoteVaultVersion, deletedAt: String) throws {
        try SelectiveRemoteVaultValidation.timestamp(deletedAt, error: .invalidDeletedAt)
        self.id = id
        self.version = version
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        try SelectiveRemoteVaultValidation.exactKeys(
            decoder,
            expected: CodingKeys.allCases.map(\.rawValue),
            error: .invalidVaultTombstone
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: SelectiveRemoteVaultValidation.uuid(
                values.decode(String.self, forKey: .id),
                error: .invalidRecordID
            ),
            version: values.decode(SelectiveRemoteVaultVersion.self, forKey: .version),
            deletedAt: values.decode(String.self, forKey: .deletedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.canonicalCloudString, forKey: .id)
        try values.encode(version, forKey: .version)
        try values.encode(deletedAt, forKey: .deletedAt)
    }
}

enum SelectiveRemoteVaultEntity: Equatable, Sendable {
    case record(SelectiveRemoteVaultRecord)
    case tombstone(SelectiveRemoteVaultTombstone)

    var id: UUID {
        switch self {
        case let .record(value): value.id
        case let .tombstone(value): value.id
        }
    }

    var version: SelectiveRemoteVaultVersion {
        switch self {
        case let .record(value): value.version
        case let .tombstone(value): value.version
        }
    }
}

struct SelectiveRemoteVaultConflict: Equatable, Sendable {
    let id: UUID
    let local: SelectiveRemoteVaultEntity
    let remote: SelectiveRemoteVaultEntity
}

struct SelectiveRemoteVaultMerge: Equatable, Sendable {
    let document: SelectiveRemoteVaultDocument
    let conflicts: [SelectiveRemoteVaultConflict]
}

struct SelectiveRemoteVaultAutomaticMerge: Equatable, Sendable {
    let document: SelectiveRemoteVaultDocument
    let resolvedConflictCount: Int
}

enum SelectiveRemoteVaultConflictChoice: String, Codable, Equatable, Hashable, Sendable {
    case local
    case remote
}

struct SelectiveRemoteVaultConflictResolution: Equatable, Sendable {
    let id: UUID
    let choice: SelectiveRemoteVaultConflictChoice
}

struct SelectiveRemoteVaultDocument: Equatable, Sendable, Codable {
    static let schemaVersion = 1
    private static let maximumBytes = 24 * 1024 * 1024
    private static let maximumEntities = 10_000

    let records: [SelectiveRemoteVaultRecord]
    let tombstones: [SelectiveRemoteVaultTombstone]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, records, tombstones
    }

    init(
        records: [SelectiveRemoteVaultRecord] = [],
        tombstones: [SelectiveRemoteVaultTombstone] = []
    ) throws {
        guard records.count + tombstones.count <= Self.maximumEntities else {
            throw SelectiveRemoteVaultDocumentError.vaultTooLarge
        }
        let allIDs = records.map(\.id) + tombstones.map(\.id)
        guard Set(allIDs).count == allIDs.count else {
            throw SelectiveRemoteVaultDocumentError.duplicateRecordID
        }
        var budget = 100_000
        for record in records {
            try SelectiveRemoteVaultValidation.json(record.data, depth: 0, budget: &budget)
        }
        self.records = records.sorted { $0.id.canonicalCloudString < $1.id.canonicalCloudString }
        self.tombstones = tombstones.sorted { $0.id.canonicalCloudString < $1.id.canonicalCloudString }
        guard try encoded().count <= Self.maximumBytes else {
            throw SelectiveRemoteVaultDocumentError.vaultTooLarge
        }
    }

    init(from decoder: Decoder) throws {
        try SelectiveRemoteVaultValidation.exactKeys(
            decoder,
            expected: CodingKeys.allCases.map(\.rawValue),
            error: .invalidVaultDocument
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw SelectiveRemoteVaultDocumentError.invalidVaultSchemaVersion
        }
        try self.init(
            records: values.decode([SelectiveRemoteVaultRecord].self, forKey: .records),
            tombstones: values.decode([SelectiveRemoteVaultTombstone].self, forKey: .tombstones)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(records, forKey: .records)
        try values.encode(tombstones, forKey: .tombstones)
    }

    static func decode(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch let error as SelectiveRemoteVaultDocumentError {
            throw error
        } catch {
            throw SelectiveRemoteVaultDocumentError.invalidVaultDocument
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func merged(with remote: Self) throws -> SelectiveRemoteVaultMerge {
        let localEntities = entityMap
        let remoteEntities = remote.entityMap
        var records: [SelectiveRemoteVaultRecord] = []
        var tombstones: [SelectiveRemoteVaultTombstone] = []
        var conflicts: [SelectiveRemoteVaultConflict] = []
        let ids = Set(localEntities.keys).union(remoteEntities.keys).sorted {
            $0.canonicalCloudString < $1.canonicalCloudString
        }

        for id in ids {
            let local = localEntities[id]
            let remote = remoteEntities[id]
            var selected = local ?? remote
            if let local, let remote {
                switch SelectiveRemoteVaultValidation.relation(local.version, remote.version) {
                case .left:
                    selected = local
                case .right:
                    selected = remote
                case .equal:
                    if local == remote {
                        selected = local
                    } else {
                        selected = nil
                        conflicts.append(.init(id: id, local: local, remote: remote))
                    }
                case .concurrent:
                    selected = nil
                    conflicts.append(.init(id: id, local: local, remote: remote))
                }
            }
            switch selected {
            case let .some(.record(value)): records.append(value)
            case let .some(.tombstone(value)): tombstones.append(value)
            case .none: break
            }
        }
        return try .init(document: .init(records: records, tombstones: tombstones), conflicts: conflicts)
    }

    func mergedKeepingNewest(
        with remote: Self,
        deviceID: UUID,
        resolvedAt: String
    ) throws -> SelectiveRemoteVaultAutomaticMerge {
        let merge = try merged(with: remote)
        let resolutions = try merge.conflicts.map { conflict in
            SelectiveRemoteVaultConflictResolution(
                id: conflict.id,
                choice: try conflict.newestChoice()
            )
        }
        let monotonicResolvedAt = merge.conflicts.reduce(resolvedAt) { result, conflict in
            max(result, max(conflict.local.eventTimestamp, conflict.remote.eventTimestamp))
        }
        return try .init(
            document: merge.document.resolving(
                merge.conflicts,
                with: resolutions,
                deviceID: deviceID,
                resolvedAt: monotonicResolvedAt
            ),
            resolvedConflictCount: merge.conflicts.count
        )
    }

    func resolving(
        _ conflicts: [SelectiveRemoteVaultConflict],
        with resolutions: [SelectiveRemoteVaultConflictResolution],
        deviceID: UUID,
        resolvedAt: String
    ) throws -> Self {
        let conflictIDs = Set(conflicts.map(\.id))
        guard conflictIDs.count == conflicts.count else {
            throw SelectiveRemoteVaultDocumentError.invalidVaultConflict
        }
        var choices: [UUID: SelectiveRemoteVaultConflictChoice] = [:]
        for resolution in resolutions {
            guard choices[resolution.id] == nil else {
                throw SelectiveRemoteVaultDocumentError.duplicateConflictResolution
            }
            guard conflictIDs.contains(resolution.id) else {
                throw SelectiveRemoteVaultDocumentError.unknownConflictResolution
            }
            choices[resolution.id] = resolution.choice
        }
        guard choices.count == conflicts.count else {
            throw SelectiveRemoteVaultDocumentError.incompleteConflictResolutions
        }

        var records = self.records
        var tombstones = self.tombstones
        let presentIDs = Set(entityMap.keys)
        for conflict in conflicts.sorted(by: { $0.id.canonicalCloudString < $1.id.canonicalCloudString }) {
            guard conflict.local.id == conflict.id,
                  conflict.remote.id == conflict.id,
                  let choice = choices[conflict.id]
            else { throw SelectiveRemoteVaultDocumentError.invalidVaultConflict }
            guard !presentIDs.contains(conflict.id) else {
                throw SelectiveRemoteVaultDocumentError.conflictRecordPresent
            }
            let selected = choice == .local ? conflict.local : conflict.remote
            let version = try conflict.local.version.joined(
                with: conflict.remote.version,
                incrementing: deviceID
            )
            switch selected {
            case let .record(value):
                records.append(try .init(
                    id: value.id,
                    type: value.type,
                    version: version,
                    modifiedAt: resolvedAt,
                    data: value.data
                ))
            case let .tombstone(value):
                tombstones.append(try .init(id: value.id, version: version, deletedAt: resolvedAt))
            }
        }
        return try .init(records: records, tombstones: tombstones)
    }

    private var entityMap: [UUID: SelectiveRemoteVaultEntity] {
        var result: [UUID: SelectiveRemoteVaultEntity] = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, .record($0)) }
        )
        for tombstone in tombstones { result[tombstone.id] = .tombstone(tombstone) }
        return result
    }
}

private extension SelectiveRemoteVaultEntity {
    var eventTimestamp: String {
        switch self {
        case let .record(value): value.modifiedAt
        case let .tombstone(value): value.deletedAt
        }
    }

    var isDeletion: Bool {
        if case .tombstone = self { return true }
        return false
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch self {
        case let .record(value):
            return Data([0]) + (try encoder.encode(value))
        case let .tombstone(value):
            return Data([1]) + (try encoder.encode(value))
        }
    }
}

private extension SelectiveRemoteVaultConflict {
    func newestChoice() throws -> SelectiveRemoteVaultConflictChoice {
        if local.eventTimestamp != remote.eventTimestamp {
            return local.eventTimestamp > remote.eventTimestamp ? .local : .remote
        }
        if local.isDeletion != remote.isDeletion {
            return local.isDeletion ? .local : .remote
        }
        let localData = try local.canonicalData()
        let remoteData = try remote.canonicalData()
        return remoteData.lexicographicallyPrecedes(localData) ? .local : .remote
    }
}

struct SelectiveRemoteTeamVaultRecordConflict: Equatable, Sendable {
    let transport: SelectiveRemoteTeamVaultConflict
    let mergedDocument: SelectiveRemoteVaultDocument
    let recordConflicts: [SelectiveRemoteVaultConflict]
}

enum SelectiveRemoteTeamVaultRecordPushOutcome: Equatable, Sendable {
    case uploaded(SelectiveRemoteTeamVaultDecryptedSnapshot, SelectiveRemoteVaultDocument)
    case conflict(SelectiveRemoteTeamVaultRecordConflict)
}

extension SelectiveRemoteTeamVaultSyncCoordinator {
    func prepareRecordConflict(
        _ conflict: SelectiveRemoteTeamVaultConflict
    ) throws -> SelectiveRemoteTeamVaultRecordConflict {
        let local = try SelectiveRemoteVaultDocument.decode(conflict.local.payload)
        let remote = try SelectiveRemoteVaultDocument.decode(conflict.remote.payload)
        let merge = try local.merged(with: remote)
        return .init(
            transport: conflict,
            mergedDocument: merge.document,
            recordConflicts: merge.conflicts
        )
    }

    func resolveRecordConflicts(
        _ conflict: SelectiveRemoteTeamVaultRecordConflict,
        resolutions: [SelectiveRemoteVaultConflictResolution],
        resolvedAt: String,
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) async throws -> SelectiveRemoteTeamVaultRecordPushOutcome {
        let resolved = try conflict.mergedDocument.resolving(
            conflict.recordConflicts,
            with: resolutions,
            deviceID: identity.deviceID,
            resolvedAt: resolvedAt
        )
        let outcome = try await resolveConflict(
            conflict.transport,
            resolvedPayload: resolved.encoded(),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        switch outcome {
        case let .uploaded(snapshot):
            return .uploaded(snapshot, try SelectiveRemoteVaultDocument.decode(snapshot.payload))
        case let .conflict(updated):
            return .conflict(try prepareRecordConflict(updated))
        }
    }

    func resolveRecordConflictsKeepingNewest(
        _ conflict: SelectiveRemoteTeamVaultConflict,
        resolvedAt: String,
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) async throws -> SelectiveRemoteTeamVaultRecordPushOutcome {
        let prepared = try prepareRecordConflict(conflict)
        let resolutions = try prepared.recordConflicts.map { value in
            SelectiveRemoteVaultConflictResolution(
                id: value.id,
                choice: try value.newestChoice()
            )
        }
        return try await resolveRecordConflicts(
            prepared,
            resolutions: resolutions,
            resolvedAt: resolvedAt,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
    }
}

private enum SelectiveRemoteVaultVectorRelation {
    case left, right, equal, concurrent
}

private enum SelectiveRemoteVaultValidation {
    private static let forbiddenKeys: Set<String> = ["__proto__", "constructor", "prototype"]

    static func exactKeys(
        _ decoder: Decoder,
        expected: [String],
        error: SelectiveRemoteVaultDocumentError
    ) throws {
        let values = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self)
        guard Set(values.allKeys.map(\.stringValue)) == Set(expected),
              values.allKeys.count == expected.count
        else { throw error }
    }

    static func uuid(
        _ value: String,
        error: SelectiveRemoteVaultDocumentError
    ) throws -> UUID {
        let normalized = value.lowercased()
        guard normalized.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil, let result = UUID(uuidString: normalized)
        else { throw error }
        return result
    }

    static func timestamp(
        _ value: String,
        error: SelectiveRemoteVaultDocumentError
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw error
        }
    }

    static func json(
        _ value: SelectiveRemoteJSONValue,
        depth: Int,
        budget: inout Int
    ) throws {
        budget -= 1
        guard budget >= 0, depth <= 32 else {
            throw SelectiveRemoteVaultDocumentError.invalidRecordData
        }
        switch value {
        case .null, .boolean, .string:
            return
        case let .number(number):
            guard number.isFinite else {
                throw SelectiveRemoteVaultDocumentError.invalidRecordData
            }
        case let .array(values):
            guard values.count <= 10_000 else {
                throw SelectiveRemoteVaultDocumentError.invalidRecordData
            }
            for value in values { try json(value, depth: depth + 1, budget: &budget) }
        case let .object(values):
            guard values.count <= 1_000,
                  values.keys.allSatisfy({ !forbiddenKeys.contains($0) })
            else { throw SelectiveRemoteVaultDocumentError.invalidRecordData }
            for key in values.keys.sorted() {
                try json(values[key]!, depth: depth + 1, budget: &budget)
            }
        }
    }

    static func relation(
        _ left: SelectiveRemoteVaultVersion,
        _ right: SelectiveRemoteVaultVersion
    ) -> SelectiveRemoteVaultVectorRelation {
        var leftAhead = false
        var rightAhead = false
        for deviceID in Set(left.counters.keys).union(right.counters.keys) {
            let comparison = (left.counters[deviceID] ?? 0) - (right.counters[deviceID] ?? 0)
            if comparison > 0 { leftAhead = true }
            if comparison < 0 { rightAhead = true }
        }
        if leftAhead, rightAhead { return .concurrent }
        if leftAhead { return .left }
        if rightAhead { return .right }
        return .equal
    }

}
