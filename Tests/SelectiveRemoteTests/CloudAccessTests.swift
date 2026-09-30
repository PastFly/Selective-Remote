import Foundation
import Testing
@testable import SelectiveRemote

struct CloudAccessTests {
    @Test func resourcePermissionVocabularyAndReveal() throws {
        #expect(CloudAccessKind.host.allowedMask == 13)
        #expect(CloudAccessKind.credential.allowedMask == 15)
        #expect(throws: CloudAccessError.self) { try CloudAccessKind.credential.validate(mask: 5) }
        #expect(try CloudAccessKind.credential.validate(mask: 7) == 7)
        #expect(throws: CloudAccessError.self) { try CloudAccessKind.forwarding.validate(mask: 5) }
    }

    @Test func canonicalOutgoingIDsAndScopeValidation() throws {
        let team = UUID(), vault = UUID(), resource = UUID()
        let reference = try SelectiveRemoteCloudAccessReference(teamID: team, vaultID: vault, resourceID: resource, kind: .credential)
        let request = CloudAccessMutation.create(principalKind: .user, principalID: UUID(), targetKind: .resource, targetID: resource, permissionMask: 7)
        let body = try CloudAccessRequest(changes: [request]).encoded()
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(resource.uuidString.lowercased()))
        #expect(!text.contains(resource.uuidString))
        let row = CloudAccessResource(id: resource, teamID: UUID(), vaultID: vault, policyKind: .credential, parentFolderID: nil, resourceVersion: 1)
        #expect(throws: CloudAccessError.self) { try row.validate(reference: reference) }
    }

    @Test func bigintVersionsAndEveryPath() throws {
        #expect(try JSONDecoder().decode(CloudAccessVersion.self, from: Data("\"42\"".utf8)).value == 42)
        #expect(try JSONDecoder().decode(CloudAccessVersion.self, from: Data("42".utf8)).value == 42)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CloudAccessVersion.self, from: Data("\"9007199254740992\"".utf8)) }
    }

    @Test @MainActor func noCommitWithoutPreviewAndSelectionInvalidates() throws {
        let reference = try SelectiveRemoteCloudAccessReference(teamID: UUID(), vaultID: UUID(), resourceID: UUID(), kind: .host)
        let coordinator = SelectiveRemoteCloudAccessCoordinator(reference: reference, client: SelectiveRemoteCloudAccessClient(client: .init()), session: .init(endpoint: URL(string: "https://example.test")!))
        #expect(!coordinator.canCommit)
        coordinator.setSelection([.init(kind: .user, id: UUID(), name: "Member")])
        #expect(!coordinator.canCommit)
        coordinator.invalidate()
        #expect(coordinator.preview == nil)
    }
}

private actor AccessFixtureTransport {
    var requests: [URLRequest] = []
    var replies: [String: [(Data, Int)]]
    init(_ replies: [String: [(Data, Int)]]) { self.replies = replies }
    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        guard var queue = replies[path], !queue.isEmpty else { throw CloudAccessError.invalidRequest }
        let reply = queue.count == 1 ? queue[0] : queue.removeFirst()
        replies[path] = queue
        return (reply.0, HTTPURLResponse(url: request.url!, statusCode: reply.1, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func captured() -> [URLRequest] { requests }
}
private struct AccessFixture {
    let reference: SelectiveRemoteCloudAccessReference
    let session = CloudAccessSession(endpoint: URL(string: "https://access.example.test")!)
    init(kind: CloudAccessKind = .host) throws { reference = try .init(teamID: UUID(), vaultID: UUID(), resourceID: UUID(), kind: kind) }
    var base: String { "/v1/teams/\(reference.teamID.canonicalCloudString)/vaults/\(reference.vaultID.canonicalCloudString)" }
    func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func client(_ transport: AccessFixtureTransport) -> SelectiveRemoteCloudAccessClient {
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken(String(repeating: "t", count: 43), for: session.endpoint)
        return .init(client: .init(tokenStore: tokens, dataLoader: { request in try await transport.load(request) }))
    }
    var context: [String: Any] { ["formatState": "V2_PREPARING", "legacyWholeVault": false, "resource_registry_v2": true, "resource_acl_v2": false, "policyMutationAvailable": true, "groupMutationAvailable": true, "blockers": []] }
    var row: [String: Any] { ["id": reference.resourceID.canonicalCloudString, "teamID": reference.teamID.canonicalCloudString, "vaultID": reference.vaultID.canonicalCloudString, "policyKind": reference.kind.rawValue, "parentFolderID": NSNull(), "resourceVersion": 1] }
    var emptyPage: [String: Any] { ["rows": [], "nextCursor": NSNull()] }
    var emptyMembers: [String: Any] { ["members": [], "nextCursor": NSNull(), "total": 0] }
    func preview(snapshot: String = String(repeating: "a", count: 64), cursor: String? = nil, details: [[String: Any]] = []) -> [String: Any] {
        ["token": "synthetic-preview", "snapshotID": snapshot, "details": details, "counts": ["pairs": details.count, "widened": 0, "lost": 0], "nextCursor": cursor.map { $0 as Any } ?? NSNull()]
    }
    func loadReplies(previews: [[String: Any]] = []) throws -> [String: [(Data, Int)]] {
        var routes = [base + "/access-context": [(try data(context), 200)], base + "/access-resources/" + reference.resourceID.canonicalCloudString: [(try data(row), 200)], base + "/access-grants": [(try data(emptyPage), 200)], base + "/who-has-access/" + reference.resourceID.canonicalCloudString: [(try data(emptyPage), 200)], "/v1/teams/" + reference.teamID.canonicalCloudString + "/members": [(try data(emptyMembers), 200)]]
        if !previews.isEmpty { routes[base + "/access-preview"] = try previews.map { (try data($0), 200) } }
        return routes
    }
}
extension CloudAccessTests {
    @Test func exactMetadataTransportBearerAndLowercaseIDs() async throws {
        let fixture = try AccessFixture(kind: .credential)
        let transport = try AccessFixtureTransport([fixture.base + "/access-resources/" + fixture.reference.resourceID.canonicalCloudString: [(fixture.data(fixture.row), 200)]])
        let row = try await fixture.client(transport).getResource(fixture.reference, session: fixture.session)
        #expect(row.policyKind == .credential)
        let requests = await transport.captured()
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "t", count: 43))
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url!.path == fixture.base + "/access-resources/" + fixture.reference.resourceID.canonicalCloudString)
    }
    @Test func foreignResourceScopeAndMissingTyped404() async throws {
        let f = try AccessFixture(); var row = f.row; row["vaultID"] = UUID().canonicalCloudString
        let path = f.base + "/access-resources/" + f.reference.resourceID.canonicalCloudString
        let t = try AccessFixtureTransport([path: [(f.data(row), 200), (f.data(["error": "access_resource_not_found"]), 404)]])
        await #expect(throws: CloudAccessError.scopeMismatch) { try await f.client(t).getResource(f.reference, session: f.session) }
        await #expect(throws: CloudAccessError.service(404, "access_resource_not_found")) { try await f.client(t).getResource(f.reference, session: f.session) }
    }
    @Test func authorization401ClearsExistingSession() async throws {
        let f = try AccessFixture(); let store = SelectiveRemoteCloudMemoryTokenStore(); store.saveToken(String(repeating: "t", count: 43), for: f.session.endpoint)
        let t = try AccessFixtureTransport([f.base + "/access-context": [(f.data(["error": "authentication_required"]), 401)]])
        let client = SelectiveRemoteCloudAccessClient(client: .init(tokenStore: store, dataLoader: { try await t.load($0) }))
        await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) { try await client.context(f.reference, session: f.session) }
        #expect(store.token(for: f.session.endpoint) == nil)
    }
    @Test func malformedMasksAndEveryEffectivePath() async throws {
        let f = try AccessFixture(); let subject = UUID(), device = UUID()
        let paths: [[String: Any]] = ["DIRECT", "INHERITED_CONTAINER", "INHERITED_CONTAINER"].map { origin in
            ["id": UUID().canonicalCloudString, "principalKind": origin == "DIRECT" ? "USER" : "GROUP", "principalID": UUID().canonicalCloudString, "grantTargetKind": origin == "DIRECT" ? "RESOURCE" : "FOLDER", "grantTargetID": UUID().canonicalCloudString, "sourceType": origin, "mask": 5, "effectiveMask": 5, "permissions": ["View", "Edit"]]
        }
        let policy: [String: Any] = ["policyAllowed": true, "policyMask": 5, "paths": paths, "blockedReasons": []]
        let usability: [String: Any] = ["deviceID": device.canonicalCloudString, "effectiveUsable": "UNKNOWN", "cryptoAvailable": "WRAP_PRESENT_UNVERIFIED", "cryptoAvailableByPermission": ["View": "WRAP_PRESENT_UNVERIFIED"], "effectiveUsableByPermission": ["View": "UNKNOWN"], "blockedReasons": []]
        var bad = policy; bad["policyMask"] = 64
        let path = f.base + "/effective-access/" + f.reference.resourceID.canonicalCloudString
        let t = try AccessFixtureTransport([path: [(f.data(["policyEffective": policy, "deviceUsability": usability]), 200), (f.data(["policyEffective": bad, "deviceUsability": usability]), 200)]])
        let result = try await f.client(t).effective(f.reference, subjectUserID: subject, subjectDeviceID: device, session: f.session)
        #expect(result.policyEffective.paths.count == 3)
        #expect(result.deviceUsability?.effectiveUsable == .unknown)
        let requests = await t.captured(); let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "subjectUserID", value: subject.canonicalCloudString)))
        #expect(query.contains(.init(name: "subjectDeviceID", value: device.canonicalCloudString)))
        await #expect(throws: CloudAccessError.invalidResponse) { try await f.client(t).effective(f.reference, subjectUserID: subject, subjectDeviceID: device, session: f.session) }
    }
    @Test @MainActor func pagedPicker1000KeepsBoundedCurrentPage() async throws {
        let f = try AccessFixture(); let cursorIDs = (0..<19).map { _ in UUID() }
        let pages = try (0..<20).map { page in
            let members: [[String: Any]] = (0..<50).map { offset in ["id": UUID().canonicalCloudString, "userID": UUID().canonicalCloudString, "username": "member\(page * 50 + offset)", "displayName": "Member \(page * 50 + offset)", "role": "viewer", "epoch": 1, "joinedAt": "2026-09-30T00:00:00Z"] }
            return (try f.data(["members": members, "total": 1000, "nextCursor": page < 19 ? cursorIDs[page].canonicalCloudString as Any : NSNull()]), 200)
        }
        let path = "/v1/teams/" + f.reference.teamID.canonicalCloudString + "/members"
        let t = AccessFixtureTransport([path: pages]); let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        for page in 0..<20 { await m.loadRecipients(groups: false, search: "member", next: page > 0); #expect(m.members.count == 50) }
        #expect(m.memberCursor == nil)
        #expect(m.members.last?.username == "member999")
        #expect(await t.captured().count == 20)
    }
    @Test @MainActor func completePreviewSelectionInvalidationRestartAndCommitCallbackData() async throws {
        let f = try AccessFixture()
        var routes = try f.loadReplies(previews: [f.preview(cursor: "50"), f.preview(), f.preview()])
        let candidate = ["userID": UUID().canonicalCloudString, "resourceID": f.reference.resourceID.canonicalCloudString, "gainedMask": 1, "lostMask": 0] as [String: Any]
        routes[f.base + "/access-commit"] = [(try f.data(["applied": 1, "grants": [["type": "GRANT_CREATE", "grantID": UUID().canonicalCloudString]], "notificationCandidates": [candidate], "counts": ["pairs": 1, "widened": 1, "lost": 0]]), 200)]
        let t = AccessFixtureTransport(routes); let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        await m.load(); m.setSelection([.init(kind: .user, id: UUID(), name: "User")]); await m.previewSelection()
        #expect(!m.canCommit)
        await m.nextPreviewPage(); #expect(m.canCommit)
        m.setMask(5); #expect(!m.canCommit); #expect(m.preview == nil)
        await m.previewSelection(); #expect(m.canCommit)
        let restarted = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        #expect(!restarted.canCommit)
        let result = await m.commit()
        #expect(result?.notificationCandidates.count == 1)
        #expect(m.committed); #expect(!m.canCommit)
        let requests = await t.captured().filter { $0.httpMethod == "POST" }
        let commit = requests.last!
        #expect(commit.value(forHTTPHeaderField: "Idempotency-Key") != nil)
        let body = try JSONSerialization.jsonObject(with: commit.httpBody!) as! [String: Any]
        #expect(body["token"] as? String == "synthetic-preview")
    }
    @Test @MainActor func changedSnapshotFailsClosedAndStaleCommitClears() async throws {
        let f = try AccessFixture(); var routes = try f.loadReplies(previews: [f.preview(cursor: "50"), f.preview(snapshot: String(repeating: "b", count: 64)), f.preview()])
        routes[f.base + "/access-commit"] = [(try f.data(["error": "access_preview_conflict"]), 409)]
        let t = AccessFixtureTransport(routes); let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        await m.load(); m.setSelection([.init(kind: .group, id: UUID(), name: "Group")]); await m.previewSelection(); await m.nextPreviewPage()
        #expect(m.preview == nil); #expect(!m.canCommit)
        await m.previewSelection(); #expect(m.canCommit)
        #expect(await m.commit() == nil); #expect(m.preview == nil); #expect(!m.committed)
    }
    @Test @MainActor func immutableLifecycleOverridesMutationFlags() async throws {
        for state in ["V1_ACTIVE", "V2_READY", "V2_ACTIVE"] {
            let f = try AccessFixture(); var context = f.context; context["formatState"] = state
            let t = try AccessFixtureTransport([f.base + "/access-context": [(f.data(context), 200)]])
            let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
            await m.load(); #expect(!m.canMutate)
            m.setSelection([.init(kind: .user, id: UUID(), name: "User")]); await m.previewSelection()
            #expect(!m.canCommit); #expect(await t.captured().count == 1)
        }
    }
    @Test func groupAddCommitIdentityMustMatch() async throws {
        let f = try AccessFixture(); let group = UUID(), membership = UUID()
        let request = CloudAccessRequest(group: .init(type: "GROUP_MEMBER_ADD", fields: ["groupID": .id(group), "targetMembershipID": .id(membership)]))
        let response: [String: Any] = ["member": ["id": UUID().canonicalCloudString, "group_id": UUID().canonicalCloudString, "user_id": UUID().canonicalCloudString, "membership_id": membership.canonicalCloudString, "membership_epoch": "1", "version": "1"], "notificationCandidates": [], "counts": ["pairs": 0, "widened": 0, "lost": 0, "affectedGrants": 0]]
        let t = try AccessFixtureTransport([f.base + "/access-group-commit": [(f.data(response), 200)]])
        await #expect(throws: CloudAccessError.scopeMismatch) { try await f.client(t).commit(f.reference, request: request, token: "synthetic", idempotencyKey: "synthetic-key", session: f.session) }
    }
}

private actor AccessPreviewRaceTransport {
    let fallback: AccessFixtureTransport
    let previewPath: String
    let first: Data
    let second: Data
    var held: CheckedContinuation<(Data, URLResponse), any Error>?
    var waiter: CheckedContinuation<Void, Never>?
    var count = 0
    var heldURL: URL?
    init(fallback: AccessFixtureTransport, previewPath: String, first: Data, second: Data) { self.fallback = fallback; self.previewPath = previewPath; self.first = first; self.second = second }
    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.url!.path == previewPath else { return try await fallback.load(request) }
        count += 1
        if count == 1 {
            heldURL = request.url!
            return try await withCheckedThrowingContinuation { continuation in
                held = continuation; waiter?.resume(); waiter = nil
            }
        }
        return (second, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func waitUntilHeld() async { if held != nil { return }; await withCheckedContinuation { waiter = $0 } }
    func release() { held?.resume(returning: (first, HTTPURLResponse(url: heldURL!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)); held = nil }
}
extension CloudAccessTests {
    @Test @MainActor func obsoletePreviewCannotOverwriteNewSelectionPreview() async throws {
        let f = try AccessFixture()
        let fallback = try AccessFixtureTransport(f.loadReplies())
        let transport = try AccessPreviewRaceTransport(fallback: fallback, previewPath: f.base + "/access-preview", first: f.data(f.preview()), second: f.data(f.preview(snapshot: String(repeating: "b", count: 64))))
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken(String(repeating: "t", count: 43), for: f.session.endpoint)
        let client = SelectiveRemoteCloudAccessClient(client: .init(tokenStore: tokens, dataLoader: { try await transport.load($0) }))
        let model = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: client, session: f.session)
        await model.load(); model.setSelection([.init(kind: .user, id: UUID(), name: "First")])
        let old = Task { await model.previewSelection() }
        await transport.waitUntilHeld()
        model.setSelection([.init(kind: .group, id: UUID(), name: "Second")])
        await model.previewSelection()
        #expect(model.preview?.snapshotID == String(repeating: "b", count: 64))
        await transport.release(); await old.value
        #expect(model.preview?.snapshotID == String(repeating: "b", count: 64)); #expect(model.canCommit)
        model.invalidate(); #expect(!model.canCommit)
    }
    @Test @MainActor func offPageCredentialGrantMetadataOwnsEditMask() async throws {
        let f = try AccessFixture(); let credential = UUID()
        var row = f.row; row["id"] = credential.canonicalCloudString; row["policyKind"] = "CREDENTIAL"
        var routes = try f.loadReplies()
        routes[f.base + "/access-resources/" + credential.canonicalCloudString] = [(try f.data(row), 200)]
        let t = AccessFixtureTransport(routes); let model = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        await model.load()
        let grant = CloudAccessGrant(id: UUID(), principal_kind: .user, principal_id: UUID(), target_kind: .resource, target_id: credential, permission_mask: 1, version: try .init(7))
        await model.edit(grant); #expect(model.currentKind == .credential)
        model.setMask(5); #expect(model.mask == 7)
        let metadataRequests = await t.captured().filter { $0.url!.path.hasSuffix(credential.canonicalCloudString) }
        #expect(metadataRequests.count == 1)
        #expect(model.editingGrant?.id == grant.id)
    }
    @Test func inheritedRawContainerMaskIsRetained() throws {
        let json: [String: Any] = ["policyAllowed": true, "policyMask": 1, "paths": [["id": UUID().canonicalCloudString, "principalKind": "GROUP", "principalID": UUID().canonicalCloudString, "grantTargetKind": "VAULT", "grantTargetID": UUID().canonicalCloudString, "sourceType": "INHERITED_CONTAINER", "mask": 29, "effectiveMask": 1, "permissions": ["View"], "permission": "View"]], "blockedReasons": []]
        let policy = try JSONDecoder().decode(CloudAccessPolicy.self, from: JSONSerialization.data(withJSONObject: json))
        try policy.validate(); #expect(policy.paths[0].mask == 29); #expect(policy.paths[0].effectiveMask == 1)
    }
    @Test func duplicateMutationsAndNullIdentityFailClosed() throws {
        let principal = UUID(), target = UUID()
        let operation = CloudAccessMutation.create(principalKind: .user, principalID: principal, targetKind: .resource, targetID: target, permissionMask: 1)
        #expect(throws: CloudAccessError.invalidRequest) { try CloudAccessRequest(changes: [operation, operation]).encoded() }
        #expect(throws: CloudAccessError.invalidRequest) { try CloudAccessRequest(group: .init(type: "GROUP_MEMBER_ADD", fields: ["groupID": .null, "targetMembershipID": .id(UUID())])).encoded() }
        let tooMany = (0..<21).map { _ in CloudAccessMutation.create(principalKind: .user, principalID: UUID(), targetKind: .resource, targetID: target, permissionMask: 1) }
        #expect(throws: CloudAccessError.invalidRequest) { try CloudAccessRequest(changes: tooMany).encoded() }
    }
    @Test func mismatchedSubjectDeviceNeverSubstitutesActor() async throws {
        let f = try AccessFixture(); let selected = UUID()
        let wire: [String: Any] = ["policyEffective": ["policyAllowed": false, "policyMask": 0, "paths": [], "blockedReasons": ["POLICY_DENIED"]], "deviceUsability": ["deviceID": UUID().canonicalCloudString, "effectiveUsable": "NO", "cryptoAvailable": "NO", "cryptoAvailableByPermission": [:], "effectiveUsableByPermission": [:], "blockedReasons": ["DEVICE_NOT_ADMITTED"]]]
        let t = try AccessFixtureTransport([f.base + "/effective-access/" + f.reference.resourceID.canonicalCloudString: [(f.data(wire), 200)]])
        await #expect(throws: CloudAccessError.scopeMismatch) { try await f.client(t).effective(f.reference, subjectUserID: UUID(), subjectDeviceID: selected, session: f.session) }
    }
}
extension CloudAccessTests {
    @Test func directoryRoutesRemainPagedAndCanonical() async throws {
        let f = try AccessFixture(); let groupID = UUID(), principalID = UUID(), subjectID = UUID()
        let teamPath = "/v1/teams/" + f.reference.teamID.canonicalCloudString
        let paths = [teamPath + "/access-vaults", teamPath + "/access-groups", teamPath + "/access-groups/" + groupID.canonicalCloudString + "/members", f.base + "/access-resources", f.base + "/resources-by-principal/GROUP/" + principalID.canonicalCloudString, f.base + "/access-devices"]
        let replies = try Dictionary(uniqueKeysWithValues: paths.map { ($0, [(try f.data(f.emptyPage), 200)]) })
        let t = AccessFixtureTransport(replies); let c = f.client(t)
        _ = try await c.vaults(teamID: f.reference.teamID, session: f.session)
        _ = try await c.groups(teamID: f.reference.teamID, session: f.session, search: "literal%_")
        _ = try await c.groupMembers(teamID: f.reference.teamID, groupID: groupID, session: f.session)
        _ = try await c.resources(f.reference, session: f.session, kind: .host)
        _ = try await c.resourcesByPrincipal(f.reference, kind: .group, principalID: principalID, session: f.session)
        _ = try await c.devices(f.reference, subjectUserID: subjectID, session: f.session)
        let captured = await t.captured()
        #expect(captured.map { $0.url!.path } == paths)
        #expect(captured.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(.init(name: "limit", value: "50")) })
        #expect(URLComponents(url: captured[1].url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(.init(name: "search", value: "literal%_")))
        #expect(URLComponents(url: captured[5].url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(.init(name: "subjectUserID", value: subjectID.canonicalCloudString)))
    }
    @Test @MainActor func equivalentRevokeKeepsServerAlternatePathsAndZeroLoss() async throws {
        let f = try AccessFixture(), subject = UUID(), grant = UUID()
        let first: [String: Any] = ["id": grant.canonicalCloudString, "principalKind": "USER", "principalID": subject.canonicalCloudString, "grantTargetKind": "RESOURCE", "grantTargetID": f.reference.resourceID.canonicalCloudString, "sourceType": "DIRECT", "mask": 1, "effectiveMask": 1, "permissions": ["View"], "permission": "View"]
        let second: [String: Any] = ["id": UUID().canonicalCloudString, "principalKind": "GROUP", "principalID": UUID().canonicalCloudString, "grantTargetKind": "FOLDER", "grantTargetID": UUID().canonicalCloudString, "sourceType": "INHERITED_CONTAINER", "mask": 33, "effectiveMask": 1, "permissions": ["View"], "permission": "View"]
        let before: [String: Any] = ["policyEffective": ["policyAllowed": true, "policyMask": 1, "paths": [first, second], "blockedReasons": []]]
        let after: [String: Any] = ["policyEffective": ["policyAllowed": true, "policyMask": 1, "paths": [second], "blockedReasons": []]]
        let detail: [String: Any] = ["vaultID": f.reference.vaultID.canonicalCloudString, "resourceID": f.reference.resourceID.canonicalCloudString, "subjectUserID": subject.canonicalCloudString, "before": before, "after": after, "gainedMask": 0, "lostMask": 0]
        let t = try AccessFixtureTransport(f.loadReplies(previews: [f.preview(details: [detail])]))
        let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        await m.load()
        await m.revoke([.init(id: grant, principal_kind: .user, principal_id: subject, target_kind: .resource, target_id: f.reference.resourceID, permission_mask: 1, version: try .init(1))])
        #expect(m.canCommit); #expect(m.impacts.count == 1)
        #expect(m.impacts[0].lostMask == 0); #expect(m.impacts[0].after.policyEffective.paths.count == 1)
        #expect(m.impacts[0].after.policyEffective.paths[0].mask == 33)
    }
    @Test func groupDirectoryRejectsForeignTeamAndInvalidVersion() async throws {
        let f = try AccessFixture()
        let row: [String: Any] = ["id": UUID().canonicalCloudString, "team_id": UUID().canonicalCloudString, "name": "Group", "version": "1"]
        var invalid = row; invalid["team_id"] = f.reference.teamID.canonicalCloudString; invalid["version"] = "01"
        let path = "/v1/teams/" + f.reference.teamID.canonicalCloudString + "/access-groups"
        let t = try AccessFixtureTransport([path: [(f.data(["rows": [row], "nextCursor": NSNull()]), 200), (f.data(["rows": [invalid], "nextCursor": NSNull()]), 200)]])
        await #expect(throws: CloudAccessError.scopeMismatch) { try await f.client(t).groups(teamID: f.reference.teamID, session: f.session) }
        await #expect(throws: CloudAccessError.invalidResponse) { try await f.client(t).groups(teamID: f.reference.teamID, session: f.session) }
    }
}
