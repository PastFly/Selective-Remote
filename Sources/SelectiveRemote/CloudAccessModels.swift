import Foundation

enum CloudAccessError: LocalizedError, Equatable, Sendable {
    case invalidRequest, invalidResponse, scopeMismatch, previewRequired
    case service(Int, String)
    var errorDescription: String? { CloudAccessLocalization.error(self) }
}

enum CloudAccessKind: String, Codable, CaseIterable, Sendable {
    case host = "HOST", credential = "CREDENTIAL", snippet = "SNIPPET", forwarding = "FORWARDING", folder = "FOLDER", vault = "VAULT"
    var allowedMask: Int {
        switch self { case .host, .snippet: 13; case .credential: 15; case .forwarding: 9; case .folder: 33; case .vault: 29 }
    }
    var permissions: [(name: String, bit: Int)] {
        var result = [(self == .credential ? "ViewMetadata" : "View", 1)]
        if self == .credential { result.append(("Reveal", 2)) }
        if self == .vault { result.append(("Create", 16)) }
        if [.host, .credential, .snippet, .vault].contains(self) { result.append(("Edit", 4)) }
        result.append((self == .folder ? "Manage" : "ManageAccess", self == .folder ? 32 : 8))
        return result
    }
    func validate(mask: Int) throws -> Int {
        guard mask > 0, mask & ~allowedMask == 0, !(self == .credential && mask & 4 != 0 && mask & 2 == 0) else { throw CloudAccessError.invalidRequest }
        return mask
    }
    var editMask: Int? { [.host, .snippet, .vault].contains(self) ? 5 : self == .credential ? 7 : nil }
}

enum CloudAccessPrincipalKind: String, Codable, Sendable { case user = "USER", group = "GROUP" }
enum CloudAccessTargetKind: String, Codable, Sendable { case vault = "VAULT", folder = "FOLDER", resource = "RESOURCE" }
enum CloudAccessFormatState: String, Codable, Sendable { case v1Active = "V1_ACTIVE", preparing = "V2_PREPARING", ready = "V2_READY", active = "V2_ACTIVE" }
enum CloudAccessUsability: String, Codable, Sendable { case yes = "YES", no = "NO", unknown = "UNKNOWN" }

struct SelectiveRemoteCloudAccessReference: Hashable, Identifiable, Sendable {
    let teamID: UUID
    let vaultID: UUID
    let resourceID: UUID
    let kind: CloudAccessKind
    let displayName: String?
    var id: String { "\(teamID.canonicalCloudString)/\(vaultID.canonicalCloudString)/\(resourceID.canonicalCloudString)" }
    init(teamID: UUID, vaultID: UUID, resourceID: UUID, kind: CloudAccessKind, displayName: String? = nil) throws {
        guard teamID.isSelectiveRemoteCloudUUID, vaultID.isSelectiveRemoteCloudUUID, resourceID.isSelectiveRemoteCloudUUID,
              kind != .vault || resourceID == vaultID else { throw CloudAccessError.invalidRequest }
        self.teamID = teamID; self.vaultID = vaultID; self.resourceID = resourceID; self.kind = kind; self.displayName = displayName
    }
    var title: String { displayName?.isEmpty == false ? displayName! : "\(CloudAccessLocalization.kind(kind.rawValue)) · \(resourceID.canonicalCloudString)" }
}

struct CloudAccessSession: Sendable { let endpoint: URL }
struct CloudAccessVersion: Codable, Equatable, Sendable {
    let value: Int
    init(_ value: Int) throws { guard value > 0, value <= 9_007_199_254_740_991 else { throw CloudAccessError.invalidResponse }; self.value = value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            guard s.first != "0", !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s) else { throw CloudAccessError.invalidResponse }
            try self.init(n)
        } else { try self.init(c.decode(Int.self)) }
    }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
}
struct CloudAccessPage<Row: Codable & Sendable>: Codable, Sendable {
    var rows: [Row]
    var nextCursor: UUID?
    func validate(limit: Int = 50) throws { guard rows.count <= limit, nextCursor?.isSelectiveRemoteCloudUUID ?? true else { throw CloudAccessError.invalidResponse } }
}
struct CloudAccessContext: Codable, Sendable {
    var formatState: CloudAccessFormatState
    var legacyWholeVault: Bool
    var resource_registry_v2: Bool
    var resource_acl_v2: Bool
    var policyMutationAvailable: Bool
    var groupMutationAvailable: Bool
    var blockers: [String]
    var canMutate: Bool { formatState == .preparing && policyMutationAvailable }
}
struct CloudAccessVault: Codable, Identifiable, Sendable { var id: UUID; var teamID: UUID; var name: String; var formatState: CloudAccessFormatState }
struct CloudAccessResource: Codable, Identifiable, Sendable {
    var id: UUID; var teamID: UUID; var vaultID: UUID; var policyKind: CloudAccessKind; var parentFolderID: UUID?; var resourceVersion: Int
    func validate(reference: SelectiveRemoteCloudAccessReference, exact: Bool = true) throws {
        guard teamID == reference.teamID, vaultID == reference.vaultID, !exact || id == reference.resourceID else { throw CloudAccessError.scopeMismatch }
        guard id.isSelectiveRemoteCloudUUID, policyKind != .vault, resourceVersion > 0, resourceVersion <= 9_007_199_254_740_991, parentFolderID?.isSelectiveRemoteCloudUUID ?? true else { throw CloudAccessError.invalidResponse }
        if exact && policyKind != reference.kind { throw CloudAccessError.scopeMismatch }
    }
}
struct CloudAccessGroup: Codable, Identifiable, Sendable {
    var id: UUID; var team_id: UUID; var name: String; var version: CloudAccessVersion
}
struct CloudAccessGroupMember: Codable, Identifiable, Sendable {
    var id: UUID; var groupID: UUID; var userID: UUID; var membershipID: UUID; var membershipEpoch: CloudAccessVersion; var version: CloudAccessVersion
}
struct CloudAccessDevice: Codable, Identifiable, Sendable { var id: UUID; var name: String; var platform: String; var admitted: Bool }
struct CloudAccessRecipient: Hashable, Identifiable, Sendable {
    var kind: CloudAccessPrincipalKind; var id: UUID; var name: String
}
struct CloudAccessGrant: Codable, Identifiable, Sendable {
    var id: UUID; var principal_kind: CloudAccessPrincipalKind; var principal_id: UUID; var target_kind: CloudAccessTargetKind; var target_id: UUID; var permission_mask: Int; var version: CloudAccessVersion
    func validate() throws {
        guard id.isSelectiveRemoteCloudUUID, principal_id.isSelectiveRemoteCloudUUID, target_id.isSelectiveRemoteCloudUUID, permission_mask > 0, permission_mask <= 63 else { throw CloudAccessError.invalidResponse }
    }
}
struct CloudAccessPath: Codable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case direct = "DIRECT", inherited = "INHERITED_CONTAINER" }
    var id: UUID; var principalKind: CloudAccessPrincipalKind; var principalID: UUID; var grantTargetKind: CloudAccessTargetKind; var grantTargetID: UUID; var sourceType: Source; var mask: Int; var effectiveMask: Int; var permissions: [String]; var permission: String?
    func validate() throws {
        let known = Set(["View", "ViewMetadata", "Reveal", "Edit", "Create", "Manage", "ManageAccess"])
        guard id.isSelectiveRemoteCloudUUID, principalID.isSelectiveRemoteCloudUUID, grantTargetID.isSelectiveRemoteCloudUUID, (0...63).contains(mask), (0...63).contains(effectiveMask), permissions.allSatisfy(known.contains), permission.map(known.contains) ?? true else { throw CloudAccessError.invalidResponse }
    }
}
struct CloudAccessPolicy: Codable, Sendable {
    var policyAllowed: Bool; var policyMask: Int; var paths: [CloudAccessPath]; var blockedReasons: [String]
    func validate() throws {
        guard (0...63).contains(policyMask), policyAllowed == (policyMask != 0) else { throw CloudAccessError.invalidResponse }
        try paths.forEach { try $0.validate() }
    }
}
struct CloudAccessDeviceUsability: Codable, Sendable {
    var deviceID: UUID; var effectiveUsable: CloudAccessUsability; var cryptoAvailable: String; var cryptoAvailableByPermission: [String: String]; var effectiveUsableByPermission: [String: String]; var blockedReasons: [String]
}
struct CloudAccessEffective: Codable, Sendable { var policyEffective: CloudAccessPolicy; var deviceUsability: CloudAccessDeviceUsability? }
struct CloudAccessWho: Codable, Identifiable, Sendable { var userID: UUID; var policyEffective: CloudAccessPolicy; var id: UUID { userID } }
struct CloudAccessPrincipalResource: Codable, Identifiable, Sendable { var resourceID: UUID; var policyEffective: CloudAccessPolicy; var id: UUID { resourceID } }
struct CloudAccessImpact: Codable, Identifiable, Sendable {
    var vaultID: UUID; var resourceID: UUID; var subjectUserID: UUID; var before: CloudAccessEffective; var after: CloudAccessEffective; var gainedMask: Int; var lostMask: Int
    var id: String { "\(vaultID)/\(resourceID)/\(subjectUserID)" }
    var alternativePathRemainsAfterRemoval: Bool {
        gainedMask == 0 && !after.policyEffective.paths.isEmpty &&
            after.policyEffective.paths.count < before.policyEffective.paths.count
    }
}
struct CloudAccessCounts: Codable, Equatable, Sendable { var pairs: Int; var widened: Int; var lost: Int; var affectedGrants: Int? }
struct CloudAccessAffectedGrant: Codable, Identifiable, Sendable { var grantID: UUID; var vaultID: UUID; var targetKind: CloudAccessTargetKind; var targetID: UUID; var permissionMask: Int; var version: CloudAccessVersion; var id: UUID { grantID } }
struct CloudAccessPreview: Codable, Sendable { var token: String; var snapshotID: String; var details: [CloudAccessImpact]; var counts: CloudAccessCounts; var nextCursor: String?; var affectedGrants: [CloudAccessAffectedGrant]? }
struct CloudAccessNotificationCandidate: Codable, Sendable { var userID: UUID; var vaultID: UUID?; var resourceID: UUID; var gainedMask: Int; var lostMask: Int }
struct CloudAccessCommittedMember: Codable, Sendable {
    var id: UUID; var group_id: UUID; var user_id: UUID; var membership_id: UUID; var membership_epoch: CloudAccessVersion; var version: CloudAccessVersion
}
struct CloudAccessCommittedChange: Codable, Sendable { var type: String; var grantID: UUID?; var resourceID: UUID? }
struct CloudAccessCommit: Codable, Sendable {
    var notificationCandidates: [CloudAccessNotificationCandidate]; var counts: CloudAccessCounts
    var applied: Int?; var grants: [CloudAccessCommittedChange]?; var group: CloudAccessGroup?; var member: CloudAccessCommittedMember?; var removed: Bool?; var edgeID: UUID?; var deleted: Bool?; var groupID: UUID?; var revokedGrants: Int?
}

// Explicit string UUID encoding: Foundation's UUID Codable emits uppercase.
struct CloudAccessMutation: Sendable, Equatable {
    let type: String
    let fields: [String: CloudAccessWireValue]
    static func create(principalKind: CloudAccessPrincipalKind, principalID: UUID, targetKind: CloudAccessTargetKind, targetID: UUID, permissionMask: Int) -> Self {
        .init(type: "GRANT_CREATE", fields: ["principalKind": .string(principalKind.rawValue), "principalID": .id(principalID), "targetKind": .string(targetKind.rawValue), "targetID": .id(targetID), "permissionMask": .number(permissionMask)])
    }
    static func change(grantID: UUID, expectedVersion: Int, permissionMask: Int) -> Self { .init(type: "GRANT_CHANGE", fields: ["grantID": .id(grantID), "expectedVersion": .number(expectedVersion), "permissionMask": .number(permissionMask)]) }
    static func revoke(grantID: UUID, expectedVersion: Int) -> Self { .init(type: "GRANT_REVOKE", fields: ["grantID": .id(grantID), "expectedVersion": .number(expectedVersion)]) }
    static func move(resourceID: UUID, newParentFolderID: UUID?, expectedResourceVersion: Int) -> Self { .init(type: "RESOURCE_MOVE", fields: ["resourceID": .id(resourceID), "newParentFolderID": newParentFolderID.map(CloudAccessWireValue.id) ?? .null, "expectedResourceVersion": .number(expectedResourceVersion)]) }
    var object: [String: CloudAccessWireValue] { fields.merging(["type": .string(type)]) { _, rhs in rhs } }
    var wireObject: [String: CloudAccessWireValue] {
        object.mapValues { $0 }.reduce(into: [:]) { result, pair in
            if pair.key.hasSuffix("ID"), case .string(let s) = pair.value { result[pair.key] = .string(s.lowercased()) }
            else if pair.key == "name", case .string(let s) = pair.value { result[pair.key] = .string(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            else { result[pair.key] = pair.value }
        }
    }
}
enum CloudAccessWireValue: Codable, Sendable, Equatable {
    case string(String), number(Int), null
    static func id(_ id: UUID) -> Self { .string(id.canonicalCloudString) }
    init(from decoder: any Decoder) throws { let c = try decoder.singleValueContainer(); if c.decodeNil() { self = .null } else if let n = try? c.decode(Int.self) { self = .number(n) } else { self = .string(try c.decode(String.self)) } }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .string(let s): try c.encode(s); case .number(let n): try c.encode(n); case .null: try c.encodeNil() } }
}
struct CloudAccessRequest: Sendable, Equatable {
    var changes: [CloudAccessMutation]?
    var group: CloudAccessMutation?
    init(changes: [CloudAccessMutation]) { self.changes = changes }
    init(group: CloudAccessMutation) { self.group = group }
    func encoded() throws -> Data {
        try validate()
        if let changes { return try JSONEncoder().encode(["changes": changes.map(\.wireObject)]) }
        return try JSONEncoder().encode(group!.wireObject)
    }
    func validate() throws {
        guard (changes != nil) != (group != nil) else { throw CloudAccessError.invalidRequest }
        let operations = changes ?? [group!]
        if changes != nil && !(1...50).contains(operations.count) { throw CloudAccessError.invalidRequest }
        var unique = Set<String>(), principals = Set<String>()
        let required: [String: Set<String>] = ["GRANT_CREATE": ["principalKind", "principalID", "targetKind", "targetID", "permissionMask"], "GRANT_CHANGE": ["grantID", "expectedVersion", "permissionMask"], "GRANT_REVOKE": ["grantID", "expectedVersion"], "RESOURCE_MOVE": ["resourceID", "newParentFolderID", "expectedResourceVersion"], "GROUP_CREATE": ["name"], "GROUP_RENAME": ["groupID", "expectedVersion", "name"], "GROUP_DELETE": ["groupID", "expectedVersion"], "GROUP_MEMBER_ADD": ["groupID", "targetMembershipID"], "GROUP_MEMBER_REMOVE": ["groupID", "edgeID", "expectedVersion"]]
        for op in operations {
            guard let keys = required[op.type], Set(op.fields.keys) == keys, (changes != nil) == !op.type.hasPrefix("GROUP_") else { throw CloudAccessError.invalidRequest }
            for (key, value) in op.fields {
                if key.hasSuffix("ID") { if value == .null && key == "newParentFolderID" { continue }; guard case .string(let s) = value, let id = UUID(uuidString: s), id.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest } }
                if key == "permissionMask" || key.hasPrefix("expected") { guard case .number(let n) = value, n > 0, n <= 9_007_199_254_740_991, key != "permissionMask" || n <= 63 else { throw CloudAccessError.invalidRequest } }
                if key == "name" { guard case .string(let s) = value, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count <= 120, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CloudAccessError.invalidRequest } }
            }
            if op.type == "GRANT_CREATE" {
                guard case .string(let p) = op.fields["principalKind"], CloudAccessPrincipalKind(rawValue: p) != nil, case .string(let t) = op.fields["targetKind"], CloudAccessTargetKind(rawValue: t) != nil else { throw CloudAccessError.invalidRequest }
                principals.insert("\(p)/\(op.wireObject["principalID"]!)")
            }
            let identity = op.wireObject["grantID"] ?? op.wireObject["resourceID"]
            let key = identity.map { String(describing: $0) } ?? ["principalKind", "principalID", "targetKind", "targetID"].map { String(describing: op.wireObject[$0]) }.joined(separator: "/")
            guard unique.insert(key).inserted else { throw CloudAccessError.invalidRequest }
        }
        guard principals.count <= 20 else { throw CloudAccessError.invalidRequest }
    }
}
