import Foundation

struct SelectiveRemoteCloudAccessClient: Sendable {
    private struct Failure: Decodable { let error: String? }
    let client: SelectiveRemoteCloudAPIClient
    init(client: SelectiveRemoteCloudAPIClient) { self.client = client }
    private func base(_ r: SelectiveRemoteCloudAccessReference) -> String { "v1/teams/\(r.teamID.canonicalCloudString)/vaults/\(r.vaultID.canonicalCloudString)" }
    private func json<T: Decodable & Sendable>(_ type: T.Type, session: CloudAccessSession, path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], query: [URLQueryItem] = []) async throws -> T {
        let (data, http) = try await client.authorizedResponse(endpoint: session.endpoint, path: path, method: method, body: body, headers: headers, queryItems: query)
        guard http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "access_request_failed"
            throw CloudAccessError.service(http.statusCode, code)
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw CloudAccessError.invalidResponse }
    }
    private func pagination(cursor: UUID?, search: String = "") throws -> [URLQueryItem] {
        guard cursor?.isSelectiveRemoteCloudUUID ?? true, search.count <= 120 else { throw CloudAccessError.invalidRequest }
        var q = [URLQueryItem(name: "limit", value: "50")]
        if let cursor { q.append(.init(name: "cursor", value: cursor.canonicalCloudString)) }
        if !search.isEmpty { q.append(.init(name: "search", value: search)) }
        return q
    }
    func context(_ r: SelectiveRemoteCloudAccessReference, session: CloudAccessSession) async throws -> CloudAccessContext {
        try await json(CloudAccessContext.self, session: session, path: "\(base(r))/access-context")
    }
    func vaults(teamID: UUID, session: CloudAccessSession, cursor: UUID? = nil) async throws -> CloudAccessPage<CloudAccessVault> {
        guard teamID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest }
        let page = try await json(CloudAccessPage<CloudAccessVault>.self, session: session, path: "v1/teams/\(teamID.canonicalCloudString)/access-vaults", query: pagination(cursor: cursor))
        try page.validate()
        guard page.rows.allSatisfy({ $0.teamID == teamID && $0.id.isSelectiveRemoteCloudUUID }) else { throw CloudAccessError.scopeMismatch }
        return page
    }
    func getResource(_ r: SelectiveRemoteCloudAccessReference, resourceID: UUID? = nil, session: CloudAccessSession) async throws -> CloudAccessResource {
        let id = resourceID ?? r.resourceID
        guard id.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest }
        let row = try await json(CloudAccessResource.self, session: session, path: "\(base(r))/access-resources/\(id.canonicalCloudString)")
        try row.validate(reference: r, exact: id == r.resourceID)
        guard row.id == id else { throw CloudAccessError.scopeMismatch }
        return row
    }
    func resources(_ r: SelectiveRemoteCloudAccessReference, session: CloudAccessSession, cursor: UUID? = nil, kind: CloudAccessKind? = nil) async throws -> CloudAccessPage<CloudAccessResource> {
        guard kind != .vault else { throw CloudAccessError.invalidRequest }
        var q = try pagination(cursor: cursor)
        if let kind { q.append(.init(name: "kind", value: kind.rawValue)) }
        let page = try await json(CloudAccessPage<CloudAccessResource>.self, session: session, path: "\(base(r))/access-resources", query: q)
        try page.validate(); try page.rows.forEach { try $0.validate(reference: r, exact: false) }
        return page
    }
    func members(teamID: UUID, session: CloudAccessSession, cursor: UUID? = nil, search: String = "") async throws -> CloudAccessMemberPage {
        guard teamID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest }
        let page = try await json(CloudAccessMemberPage.self, session: session, path: "v1/teams/\(teamID.canonicalCloudString)/members", query: pagination(cursor: cursor, search: search))
        guard page.members.count <= 50, page.total >= 0, page.nextCursor?.isSelectiveRemoteCloudUUID ?? true, page.members.allSatisfy({ $0.id.isSelectiveRemoteCloudUUID && $0.userID.isSelectiveRemoteCloudUUID && $0.epoch > 0 }) else { throw CloudAccessError.invalidResponse }
        return page
    }
    func groups(teamID: UUID, session: CloudAccessSession, cursor: UUID? = nil, search: String = "") async throws -> CloudAccessPage<CloudAccessGroup> {
        guard teamID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest }
        let page = try await json(CloudAccessPage<CloudAccessGroup>.self, session: session, path: "v1/teams/\(teamID.canonicalCloudString)/access-groups", query: pagination(cursor: cursor, search: search))
        try page.validate(); guard page.rows.allSatisfy({ $0.team_id == teamID && $0.id.isSelectiveRemoteCloudUUID }) else { throw CloudAccessError.scopeMismatch }; return page
    }
    func groupMembers(teamID: UUID, groupID: UUID, session: CloudAccessSession, cursor: UUID? = nil) async throws -> CloudAccessPage<CloudAccessGroupMember> {
        guard teamID.isSelectiveRemoteCloudUUID, groupID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest }
        let page = try await json(CloudAccessPage<CloudAccessGroupMember>.self, session: session, path: "v1/teams/\(teamID.canonicalCloudString)/access-groups/\(groupID.canonicalCloudString)/members", query: pagination(cursor: cursor))
        try page.validate(); guard page.rows.allSatisfy({ $0.groupID == groupID && $0.id.isSelectiveRemoteCloudUUID && $0.userID.isSelectiveRemoteCloudUUID && $0.membershipID.isSelectiveRemoteCloudUUID }) else { throw CloudAccessError.scopeMismatch }; return page
    }
    func grants(_ r: SelectiveRemoteCloudAccessReference, session: CloudAccessSession, cursor: UUID? = nil) async throws -> CloudAccessPage<CloudAccessGrant> {
        let page = try await json(CloudAccessPage<CloudAccessGrant>.self, session: session, path: "\(base(r))/access-grants", query: pagination(cursor: cursor))
        try page.validate(); try page.rows.forEach { try $0.validate() }; return page
    }
    func whoHas(_ r: SelectiveRemoteCloudAccessReference, session: CloudAccessSession, cursor: UUID? = nil) async throws -> CloudAccessPage<CloudAccessWho> {
        let page = try await json(CloudAccessPage<CloudAccessWho>.self, session: session, path: "\(base(r))/who-has-access/\(r.resourceID.canonicalCloudString)", query: pagination(cursor: cursor))
        try page.validate(); try page.rows.forEach { guard $0.userID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidResponse }; try $0.policyEffective.validate() }; return page
    }
    func resourcesByPrincipal(_ r: SelectiveRemoteCloudAccessReference, kind: CloudAccessPrincipalKind, principalID: UUID, session: CloudAccessSession, cursor: UUID? = nil) async throws -> CloudAccessPage<CloudAccessPrincipalResource> {
        guard principalID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest }
        let page = try await json(CloudAccessPage<CloudAccessPrincipalResource>.self, session: session, path: "\(base(r))/resources-by-principal/\(kind.rawValue)/\(principalID.canonicalCloudString)", query: pagination(cursor: cursor))
        try page.validate(); try page.rows.forEach { guard $0.resourceID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidResponse }; try $0.policyEffective.validate() }; return page
    }
    func devices(_ r: SelectiveRemoteCloudAccessReference, subjectUserID: UUID, session: CloudAccessSession, cursor: UUID? = nil) async throws -> CloudAccessPage<CloudAccessDevice> {
        guard subjectUserID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest }
        var q = try pagination(cursor: cursor); q.append(.init(name: "subjectUserID", value: subjectUserID.canonicalCloudString))
        let page = try await json(CloudAccessPage<CloudAccessDevice>.self, session: session, path: "\(base(r))/access-devices", query: q)
        try page.validate(); guard page.rows.allSatisfy({ $0.id.isSelectiveRemoteCloudUUID }) else { throw CloudAccessError.invalidResponse }; return page
    }
    func effective(_ r: SelectiveRemoteCloudAccessReference, subjectUserID: UUID, subjectDeviceID: UUID, session: CloudAccessSession) async throws -> CloudAccessEffective {
        guard subjectUserID.isSelectiveRemoteCloudUUID, subjectDeviceID.isSelectiveRemoteCloudUUID else { throw CloudAccessError.invalidRequest }
        let result = try await json(CloudAccessEffective.self, session: session, path: "\(base(r))/effective-access/\(r.resourceID.canonicalCloudString)", query: [.init(name: "subjectUserID", value: subjectUserID.canonicalCloudString), .init(name: "subjectDeviceID", value: subjectDeviceID.canonicalCloudString)])
        try result.policyEffective.validate()
        guard let usability = result.deviceUsability, usability.deviceID == subjectDeviceID else { throw CloudAccessError.scopeMismatch }
        guard ["NO", "WRAP_PRESENT_UNVERIFIED", "NOT_REQUIRED"].contains(usability.cryptoAvailable), usability.cryptoAvailableByPermission.values.allSatisfy({ ["NO", "WRAP_PRESENT_UNVERIFIED", "NOT_REQUIRED"].contains($0) }), usability.effectiveUsableByPermission.values.allSatisfy({ ["YES", "NO", "UNKNOWN"].contains($0) }) else { throw CloudAccessError.invalidResponse }
        return result
    }
    func preview(_ r: SelectiveRemoteCloudAccessReference, request: CloudAccessRequest, session: CloudAccessSession, cursor: String? = nil) async throws -> CloudAccessPreview {
        let requestData = try request.encoded()
        var body = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
        body = ["request": body]
        if let cursor { guard let n = Int(cursor), (0...1000).contains(n), String(n) == cursor else { throw CloudAccessError.invalidRequest }; body["cursor"] = cursor }
        let result = try await json(CloudAccessPreview.self, session: session, path: "\(base(r))/\(request.changes == nil ? "access-group-preview" : "access-preview")", method: "POST", body: JSONSerialization.data(withJSONObject: body))
        guard !result.token.isEmpty, result.snapshotID.count == 64, result.snapshotID.allSatisfy({ "0123456789abcdef".contains($0) }), result.details.count <= 50, (result.affectedGrants?.count ?? 0) <= 50, (0...1000).contains(result.counts.pairs), result.counts.widened >= 0, result.counts.lost >= 0 else { throw CloudAccessError.invalidResponse }
        if let next = result.nextCursor { guard let n = Int(next), n > Int(cursor ?? "0")!, n <= 1000, String(n) == next else { throw CloudAccessError.invalidResponse } }
        for d in result.details {
            guard d.vaultID.isSelectiveRemoteCloudUUID, d.resourceID.isSelectiveRemoteCloudUUID, d.subjectUserID.isSelectiveRemoteCloudUUID, request.changes == nil || d.vaultID == r.vaultID, (0...63).contains(d.gainedMask), (0...63).contains(d.lostMask) else { throw CloudAccessError.scopeMismatch }
            try d.before.policyEffective.validate(); try d.after.policyEffective.validate()
        }
        if request.changes == nil { guard let n = result.counts.affectedGrants, n >= 0, result.affectedGrants != nil else { throw CloudAccessError.invalidResponse } }
        for g in result.affectedGrants ?? [] { guard g.grantID.isSelectiveRemoteCloudUUID, g.vaultID.isSelectiveRemoteCloudUUID, g.targetID.isSelectiveRemoteCloudUUID, (1...63).contains(g.permissionMask) else { throw CloudAccessError.invalidResponse } }
        return result
    }
    func commit(_ r: SelectiveRemoteCloudAccessReference, request: CloudAccessRequest, token: String, idempotencyKey: String, session: CloudAccessSession) async throws -> CloudAccessCommit {
        guard !token.isEmpty, !idempotencyKey.isEmpty else { throw CloudAccessError.previewRequired }
        let object = try JSONSerialization.jsonObject(with: request.encoded())
        let result = try await json(CloudAccessCommit.self, session: session, path: "\(base(r))/\(request.changes == nil ? "access-group-commit" : "access-commit")", method: "POST", body: JSONSerialization.data(withJSONObject: ["request": object, "token": token]), headers: ["Idempotency-Key": idempotencyKey])
        for c in result.notificationCandidates { guard c.userID.isSelectiveRemoteCloudUUID, c.resourceID.isSelectiveRemoteCloudUUID, c.vaultID?.isSelectiveRemoteCloudUUID ?? true, request.changes == nil || c.vaultID == nil || c.vaultID == r.vaultID, (0...63).contains(c.gainedMask), (0...63).contains(c.lostMask) else { throw CloudAccessError.scopeMismatch } }
        guard (0...1000).contains(result.counts.pairs), (0...result.counts.pairs).contains(result.counts.widened), (0...result.counts.pairs).contains(result.counts.lost) else { throw CloudAccessError.invalidResponse }
        if let changes = request.changes {
            guard result.applied == changes.count, let receipts = result.grants, receipts.count == changes.count else { throw CloudAccessError.invalidResponse }
            for (change, receipt) in zip(changes, receipts) {
                guard change.type == receipt.type else { throw CloudAccessError.scopeMismatch }
                if change.type == "RESOURCE_MOVE" {
                    guard let id = receipt.resourceID, id.isSelectiveRemoteCloudUUID, change.wireObject["resourceID"] == .id(id) else { throw CloudAccessError.scopeMismatch }
                } else {
                    guard let id = receipt.grantID, id.isSelectiveRemoteCloudUUID, change.type == "GRANT_CREATE" || change.wireObject["grantID"] == .id(id) else { throw CloudAccessError.scopeMismatch }
                }
            }
        }
        if let group = request.group {
            if group.type == "GROUP_MEMBER_ADD" {
                guard let member = result.member, member.id.isSelectiveRemoteCloudUUID, member.user_id.isSelectiveRemoteCloudUUID,
                      group.wireObject["groupID"] == .id(member.group_id), group.wireObject["targetMembershipID"] == .id(member.membership_id)
                else { throw CloudAccessError.scopeMismatch }
            }
            if ["GROUP_CREATE", "GROUP_RENAME"].contains(group.type) { guard let g = result.group, g.team_id == r.teamID, g.id.isSelectiveRemoteCloudUUID, group.wireObject["groupID"] == nil || group.wireObject["groupID"] == .id(g.id) else { throw CloudAccessError.scopeMismatch } }
            if group.type == "GROUP_DELETE" { guard result.deleted == true, let id = result.groupID, group.wireObject["groupID"] == .id(id) else { throw CloudAccessError.scopeMismatch } }
            if group.type == "GROUP_MEMBER_REMOVE" { guard result.removed == true, let id = result.edgeID, group.wireObject["edgeID"] == .id(id) else { throw CloudAccessError.scopeMismatch } }
        }
        return result
    }
}
struct CloudAccessMemberPage: Codable, Sendable { var members: [SelectiveRemoteCloudTeamMember]; var nextCursor: UUID?; var total: Int }
