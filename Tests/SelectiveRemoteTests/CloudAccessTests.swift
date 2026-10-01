import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import SelectiveRemote

@MainActor
private func renderedAccessText(_ model: SelectiveRemoteCloudAccessCoordinator, output: URL) async throws -> [String] {
    let host = NSHostingView(rootView: SelectiveRemoteCloudResourceAccessView(coordinator: model)
        .frame(width: 640, height: 680))
    host.frame = CGRect(x: 0, y: 0, width: 640, height: 680)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(50))
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    let image = try #require(CGWindowListCreateImage(.null, .optionIncludingWindow,
        CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: output)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

struct CloudAccessTests {
    @Test func deviceCodesHaveLocalizedSafeCopy() throws {
        #expect(CloudAccessLocalization.deviceStatus("YES", english: false) == "Доступно")
        #expect(CloudAccessLocalization.deviceStatus("WRAP_PRESENT_UNVERIFIED", english: true) == "Key present, unverified")
        #expect(CloudAccessLocalization.deviceStatus("SECRET_CANARY", english: true) == "Status unknown")
        #expect(CloudAccessLocalization.deviceReason("KEY_UNAVAILABLE", english: false) == "Ключ ресурса недоступен")
        #expect(CloudAccessLocalization.deviceReason("SECRET_CANARY", english: true) == "Availability reason unknown")
        #expect(CloudAccessLocalization.kind("USER", english: false) == "Участник")
        #expect(CloudAccessLocalization.kind("FOLDER", english: true) == "Folder")
        #expect(CloudAccessLocalization.kind("HOST", english: false) == "Хост")
        #expect(CloudAccessLocalization.kind("HOST", english: true) == "Host")
        #expect(CloudAccessLocalization.kind("CREDENTIAL", english: false) == "Учётные данные")
        #expect(CloudAccessLocalization.kind("FORWARDING", english: true) == "Forwarding")
        #expect(CloudAccessLocalization.kind("SECRET_CANARY", english: false) == "Тип неизвестен")
        let reference = try SelectiveRemoteCloudAccessReference(teamID: UUID(), vaultID: UUID(), resourceID: UUID(), kind: .host)
        #expect(!reference.title.hasPrefix("HOST ·"))
        #expect(reference.title.hasSuffix(reference.resourceID.canonicalCloudString))
    }
    @Test func firstGrantDoesNotShowRevokeGuidance() {
        #expect(CloudAccessLocalization.revokeGuidance(hasExistingGrants: false) == nil)
        #expect(CloudAccessLocalization.revokeGuidance(hasExistingGrants: true, english: true)?.contains("Revoking one path") == true)
    }
    @Test func firstGrantAndEquivalentRevokeImpactCopy() {
        let path = CloudAccessPath(id: UUID(), principalKind: .user, principalID: UUID(),
            grantTargetKind: .resource, grantTargetID: UUID(), sourceType: .direct,
            mask: 1, effectiveMask: 1, permissions: ["View"], permission: "View")
        let other = CloudAccessPath(id: UUID(), principalKind: .group, principalID: UUID(),
            grantTargetKind: .folder, grantTargetID: UUID(), sourceType: .inherited,
            mask: 1, effectiveMask: 1, permissions: ["View"], permission: "View")
        let empty = CloudAccessEffective(policyEffective: .init(policyAllowed: false, policyMask: 0,
            paths: [], blockedReasons: []), deviceUsability: nil)
        let initial = CloudAccessEffective(policyEffective: .init(policyAllowed: true, policyMask: 1,
            paths: [path], blockedReasons: []), deviceUsability: nil)
        let both = CloudAccessEffective(policyEffective: .init(policyAllowed: true, policyMask: 1,
            paths: [path, other], blockedReasons: []), deviceUsability: nil)
        let surviving = CloudAccessEffective(policyEffective: .init(policyAllowed: true, policyMask: 1,
            paths: [other], blockedReasons: []), deviceUsability: nil)
        let firstGrant = CloudAccessImpact(vaultID: UUID(), resourceID: UUID(), subjectUserID: UUID(),
            before: empty, after: initial, gainedMask: 1, lostMask: 0)
        let equivalentRevoke = CloudAccessImpact(vaultID: UUID(), resourceID: UUID(), subjectUserID: UUID(),
            before: both, after: surviving, gainedMask: 0, lostMask: 0)
        #expect(!firstGrant.alternativePathRemainsAfterRemoval)
        #expect(equivalentRevoke.alternativePathRemainsAfterRemoval)
    }
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
    func preview(snapshot: String = String(repeating: "a", count: 64), cursor: String? = nil, details: [[String: Any]] = [], pairs: Int? = nil) -> [String: Any] {
        ["token": "synthetic-preview", "snapshotID": snapshot, "details": details, "counts": ["pairs": pairs ?? details.count, "widened": 0, "lost": 0], "nextCursor": cursor.map { $0 as Any } ?? NSNull()]
    }
    func loadReplies(previews: [[String: Any]] = []) throws -> [String: [(Data, Int)]] {
        var routes = [base + "/access-context": [(try data(context), 200)], base + "/access-resources/" + reference.resourceID.canonicalCloudString: [(try data(row), 200)], base + "/access-grants": [(try data(emptyPage), 200)], base + "/who-has-access/" + reference.resourceID.canonicalCloudString: [(try data(emptyPage), 200)], "/v1/teams/" + reference.teamID.canonicalCloudString + "/members": [(try data(emptyMembers), 200)]]
        if !previews.isEmpty { routes[base + "/access-preview"] = try previews.map { (try data($0), 200) } }
        return routes
    }
}
extension CloudAccessTests {
    @Test @MainActor func repreviewPreservesBoundMoveRequest() async throws {
        let f = try AccessFixture()
        let t = try AccessFixtureTransport(f.loadReplies(previews: [f.preview(), f.preview()]))
        let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        await m.load()
        let request = CloudAccessRequest(changes: [.move(resourceID: f.reference.resourceID,
            newParentFolderID: UUID(), expectedResourceVersion: 1)])
        await m.prepare(request)
        #expect(m.canCommit)
        await m.repreview()
        #expect(m.request == request)
        #expect(m.canCommit)
        let previews = await t.captured().filter { $0.url?.path == f.base + "/access-preview" }
        #expect(previews.count == 2)
        if previews.count == 2 {
            #expect(previews[0].httpBody == previews[1].httpBody)
            #expect(!String(decoding: previews[1].httpBody ?? Data(), as: UTF8.self).contains("GRANT_CREATE"))
        }
    }
    @Test @MainActor @available(macOS, deprecated: 14)
    func actualAccessSheetWindowServerMatrix() async throws {
        let output = ProcessInfo.processInfo.environment["SR_CAPTURE_ACCESS_MATRIX"]
        if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
        let languageKey = "SelectiveRemote.applicationLanguage.v1"
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        defer {
            if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
        }
        for scenario in ["loading", "empty", "v1", "preparing", "ready", "active",
                         "direct", "group", "multiple-paths", "no-key", "unknown", "error"] {
            let fixture = try AccessFixture()
            var routes = try fixture.loadReplies()
            if scenario == "error" {
                routes[fixture.base + "/access-context"] = [(try fixture.data(["error": "access_request_failed"]), 503)]
            } else if scenario != "loading" {
                var context = fixture.context
                context["formatState"] = ["v1": "V1_ACTIVE", "ready": "V2_READY", "active": "V2_ACTIVE"][scenario] ?? "V2_PREPARING"
                context["policyMutationAvailable"] = scenario == "preparing" || scenario == "empty"
                context["groupMutationAvailable"] = scenario == "preparing" || scenario == "empty"
                routes[fixture.base + "/access-context"] = [(try fixture.data(context), 200)]
            }
            let subject = UUID(), device = UUID()
            if ["direct", "group", "multiple-paths"].contains(scenario) {
                func path(_ group: Bool) -> [String: Any] {
                    ["id": UUID().canonicalCloudString,
                     "principalKind": group ? "GROUP" : "USER", "principalID": UUID().canonicalCloudString,
                     "grantTargetKind": group ? "FOLDER" : "RESOURCE", "grantTargetID": fixture.reference.resourceID.canonicalCloudString,
                     "sourceType": group ? "INHERITED_CONTAINER" : "DIRECT", "mask": 1, "effectiveMask": 1,
                     "permissions": ["View"]]
                }
                let paths = scenario == "direct" ? [path(false)] : scenario == "group" ? [path(true)] : [path(false), path(true)]
                let policy: [String: Any] = ["policyAllowed": true, "policyMask": 1, "paths": paths, "blockedReasons": []]
                routes[fixture.base + "/who-has-access/" + fixture.reference.resourceID.canonicalCloudString] =
                    [(try fixture.data(["rows": [["userID": subject.canonicalCloudString, "policyEffective": policy]], "nextCursor": NSNull()]), 200)]
            }
            if ["no-key", "unknown"].contains(scenario) {
                let member: [String: Any] = ["id": UUID().canonicalCloudString, "userID": subject.canonicalCloudString,
                    "username": "fixture", "displayName": "Fixture member", "role": "viewer", "epoch": 1,
                    "joinedAt": "2026-09-30T00:00:00Z"]
                routes["/v1/teams/" + fixture.reference.teamID.canonicalCloudString + "/members"] =
                    [(try fixture.data(["members": [member], "nextCursor": NSNull(), "total": 1]), 200)]
                routes[fixture.base + "/access-devices"] = [(try fixture.data(["rows": [["id": device.canonicalCloudString,
                    "name": "Fixture device", "platform": "macOS", "admitted": true]], "nextCursor": NSNull()]), 200)]
                let usable = scenario == "no-key" ? "NO" : "UNKNOWN"
                let crypto = scenario == "no-key" ? "NO" : "WRAP_PRESENT_UNVERIFIED"
                let policy: [String: Any] = ["policyAllowed": true, "policyMask": 1, "paths": [], "blockedReasons": []]
                let deviceState: [String: Any] = ["deviceID": device.canonicalCloudString, "effectiveUsable": usable,
                    "cryptoAvailable": crypto, "cryptoAvailableByPermission": ["View": crypto],
                    "effectiveUsableByPermission": ["View": usable],
                    "blockedReasons": scenario == "no-key" ? ["KEY_UNAVAILABLE"] : []]
                routes[fixture.base + "/effective-access/" + fixture.reference.resourceID.canonicalCloudString] =
                    [(try fixture.data(["policyEffective": policy, "deviceUsability": deviceState]), 200)]
            }
            @MainActor func freshCoordinator() async -> SelectiveRemoteCloudAccessCoordinator {
                let transport = AccessFixtureTransport(routes)
                let session = CloudAccessSession(endpoint: fixture.session.endpoint)
                let client: SelectiveRemoteCloudAccessClient
                if scenario == "loading" {
                    let tokens = SelectiveRemoteCloudMemoryTokenStore()
                    tokens.saveToken(String(repeating: "t", count: 43), for: session.endpoint)
                    client = .init(client: .init(tokenStore: tokens, dataLoader: { request in
                        try await Task.sleep(for: .seconds(1))
                        return try await transport.load(request)
                    }))
                } else {
                    client = fixture.client(transport)
                }
                let coordinator = SelectiveRemoteCloudAccessCoordinator(reference: fixture.reference,
                    client: client, session: session)
                if scenario != "loading" { await coordinator.load() }
                if scenario != "loading" && scenario != "error" {
                    #expect(coordinator.errorMessage == nil, "\(scenario): \(coordinator.errorMessage ?? "unknown")")
                }
                if ["no-key", "unknown"].contains(scenario) {
                    await coordinator.selectSubject(subject)
                    await coordinator.selectDevice(device)
                    #expect(coordinator.effective?.deviceUsability?.effectiveUsable.rawValue == (scenario == "no-key" ? "NO" : "UNKNOWN"))
                }
                if ["direct", "group", "multiple-paths"].contains(scenario) {
                    #expect(coordinator.who.first?.policyEffective.paths.count == (scenario == "multiple-paths" ? 2 : 1))
                }
                return coordinator
            }
            guard let output else { _ = await freshCoordinator(); continue }
            let section: CloudAccessSection = ["direct", "group", "multiple-paths"].contains(scenario) ? .who :
                (["no-key", "unknown"].contains(scenario) ? .effective : .share)
            for english in [false, true] {
                UserDefaults.standard.set(english ? "english" : "russian", forKey: "SelectiveRemote.applicationLanguage.v1")
                for dark in [false, true] {
                    for width in [480, 820] {
                        // Closing the real view invalidates its session. Every window
                        // needs an independently loaded coordinator/client/session.
                        let coordinator = await freshCoordinator()
                        let view = SelectiveRemoteCloudResourceAccessView(coordinator: coordinator, initialSection: section)
                            .frame(width: CGFloat(width), height: 680)
                            .preferredColorScheme(dark ? .dark : .light)
                        let hosting = NSHostingView(rootView: view)
                        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 680)
                        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.contentView = hosting
                        window.makeKeyAndOrderFront(nil)
                        try await Task.sleep(for: .milliseconds(50))
                        window.layoutIfNeeded()
                        hosting.layoutSubtreeIfNeeded()
                        if scenario == "loading" { #expect(coordinator.busy && coordinator.context == nil) }
                        let image = try #require(CGWindowListCreateImage(.null, .optionIncludingWindow,
                            CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        window.orderOut(nil)
                        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                        let name = "\(scenario)-\(english ? "en" : "ru")-\(dark ? "graphite" : "light")-\(width).png"
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: output).appending(path: name))
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        recognition.recognitionLanguages = [english ? "en-US" : "ru-RU"]
                        try VNImageRequestHandler(cgImage: image).perform([recognition])
                        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .joined(separator: " ")
                        try text.write(to: URL(fileURLWithPath: output).appending(path: name + ".ocr.txt"),
                            atomically: true, encoding: .utf8)
                        #expect(text.contains(english ? "Share" : "Поделиться"), "\(name): \(text)")
                        switch scenario {
                        case "loading": break // The pending request/spinner is asserted above.
                        case "error":
                            #expect(text.contains(english ? "Cloud could not complete the access request" : "Cloud не выполнил запрос доступа"), "\(name): \(text)")
                            #expect(text.contains(english ? "Retry" : "Повторить"), "\(name): \(text)")
                        case "v1":
                            #expect(text.contains(english ? "Whole-Vault access" : "Общий доступ к Vault"), "\(name): \(text)")
                        case "ready", "active":
                            #expect(text.contains(english ? "Access is read-only" : "Доступ только для просмотра"), "\(name): \(text)")
                            #expect(text.contains(english ? "Contact the team Owner" : "Обратитесь к владельцу команды"), "\(name): \(text)")
                        case "empty", "preparing":
                            #expect(text.contains(english ? "Individual resource access" : "Доступ к отдельным ресурсам"), "\(name): \(text)")
                            #expect(text.contains(english ? "Permissions" : "Разрешения"), "\(name): \(text)")
                            #expect(text.contains(english ? "Search recipients" : "Найти получателя"), "\(name): \(text)")
                        case "direct", "group", "multiple-paths":
                            #expect(text.contains(english ? "Member permissions: granted" : "Разрешения участника: предоставлены"), "\(name): \(text)")
                            if scenario != "group" {
                                #expect(text.contains(english ? "Granted on this resource" : "Прямой доступ к этому ресурсу"), "\(name): \(text)")
                            }
                            if scenario != "direct" {
                                #expect(text.contains(english ? "Inherited from a parent folder" : "Наследуется от родительской папки"), "\(name): \(text)")
                            }
                        default: break // Device content is asserted below.
                        }
                        if ["no-key", "unknown"].contains(scenario) {
                            let state = scenario == "no-key"
                                ? (english ? "Unavailable" : "Недоступно")
                                : (english ? "Unverified" : "Не подтверждено")
                            #expect(text.contains((english ? "Device usability: " : "Доступность на устройстве: ") + state), "\(name): \(text)")
                            #expect(text.contains((english ? "View: " : "Просмотр: ") + state), "\(name): \(text)")
                        }
                    }
                }
            }
        }
    }
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
        let details = (0..<51).map { _ in f.impact(resource: f.reference.resourceID) }
        var routes = try f.loadReplies(previews: [f.preview(cursor: "50", details: Array(details.prefix(50)), pairs: 51), f.preview(details: Array(details.suffix(1)), pairs: 51), f.preview()])
        let candidate = ["userID": UUID().canonicalCloudString, "resourceID": f.reference.resourceID.canonicalCloudString, "gainedMask": 1, "lostMask": 0] as [String: Any]
        routes[f.base + "/access-commit"] = [(try f.data(["applied": 1, "grants": [["type": "GRANT_CREATE", "grantID": UUID().canonicalCloudString]], "notificationCandidates": [candidate], "counts": ["pairs": 1, "widened": 1, "lost": 0]]), 200)]
        let t = AccessFixtureTransport(routes); let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        await m.load(); m.setSelection([.init(kind: .group, id: UUID(), name: "Group with 51 members")]); await m.previewSelection()
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
        let f = try AccessFixture(); let details = (0..<51).map { _ in f.impact(resource: f.reference.resourceID) }; var routes = try f.loadReplies(previews: [f.preview(cursor: "50", details: Array(details.prefix(50)), pairs: 51), f.preview(snapshot: String(repeating: "b", count: 64), details: Array(details.suffix(1)), pairs: 51), f.preview()])
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

private actor AccessHeldReplyTransport {
    let fallback: AccessFixtureTransport
    let heldPath: String
    var held: CheckedContinuation<(Data, URLResponse), any Error>?
    var waiter: CheckedContinuation<Void, Never>?
    var heldURL: URL?
    var requests = 0
    var didHold = false

    init(fallback: AccessFixtureTransport, heldPath: String) {
        self.fallback = fallback; self.heldPath = heldPath
    }
    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        guard request.url?.path == heldPath, !didHold else { return try await fallback.load(request) }
        didHold = true
        heldURL = request.url
        return try await withCheckedThrowingContinuation { continuation in
            held = continuation; waiter?.resume(); waiter = nil
        }
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release(_ data: Data, statusCode: Int = 200) {
        held?.resume(returning: (data, HTTPURLResponse(url: heldURL!, statusCode: statusCode,
            httpVersion: "HTTP/1.1", headerFields: nil)!))
        held = nil
    }
}

extension CloudAccessTests {
    @Test @MainActor func visibleAccessSheetInvalidatesOnAccountChange() async throws {
        let f = try AccessFixture()
        let transport = try AccessFixtureTransport(f.loadReplies())
        let model = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(transport), session: f.session)
        await model.load()
        #expect(model.context != nil)
        let host = NSHostingView(rootView: SelectiveRemoteCloudResourceAccessView(coordinator: model)
            .frame(width: 640, height: 680))
        host.frame = CGRect(x: 0, y: 0, width: 640, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.context != nil)
        NotificationCenter.default.post(name: .selectiveRemoteCloudSessionChanged, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.context == nil && model.resource == nil && !model.canMutate)
        let count = await transport.captured().count
        await model.load()
        #expect(await transport.captured().count == count)
    }

    @Test @MainActor func accountChangeClearsLoadedAccessAndRejectsOldReference() async throws {
        let f = try AccessFixture(), grantID = UUID(), subject = UUID()
        var routes = try f.loadReplies(previews: [f.preview()])
        routes[f.base + "/access-grants"] = [(try f.data(["rows": [f.grantWire(id: grantID, version: 1)], "nextCursor": NSNull()]), 200)]
        routes[f.base + "/who-has-access/" + f.reference.resourceID.canonicalCloudString] =
            [(try f.data(["rows": [["userID": subject.canonicalCloudString,
                "policyEffective": ["policyAllowed": true, "policyMask": 1, "paths": [], "blockedReasons": []]]],
                "nextCursor": NSNull()]), 200)]
        let transport = AccessFixtureTransport(routes)
        let model = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(transport), session: f.session)
        await model.load()
        model.setSelection([.init(kind: .user, id: UUID(), name: "Account A")])
        await model.previewSelection()
        #expect(model.context != nil && model.resource != nil && !model.grants.isEmpty && !model.who.isEmpty)
        #expect(model.canCommit)
        let requestCount = await transport.captured().count
        model.invalidateSession()
        #expect(model.context == nil && model.resource == nil && model.grants.isEmpty && model.who.isEmpty)
        #expect(model.members.isEmpty && model.groups.isEmpty && model.selection.isEmpty && model.preview == nil)
        #expect(!model.canMutate && !model.canCommit && !model.canRepreview)
        await model.load()
        await model.previewSelection()
        #expect(await model.commit() == nil)
        #expect(await transport.captured().count == requestCount)
    }

    @Test @MainActor func accountChangeDiscardsDelayedAccessReplies() async throws {
        for (pathSuffix, failure) in [("/access-resources/", false), ("/access-grants", false),
                                      ("/who-has-access/", false), ("/access-grants", true)] {
            let f = try AccessFixture()
            let routes = try f.loadReplies()
            let path = pathSuffix.hasSuffix("/") ? f.base + pathSuffix + f.reference.resourceID.canonicalCloudString : f.base + pathSuffix
            let reply = try failure ? f.data(["error": "access_request_failed"]) : #require(routes[path]?.first?.0)
            let fallback = AccessFixtureTransport(routes)
            let transport = AccessHeldReplyTransport(fallback: fallback, heldPath: path)
            let tokens = SelectiveRemoteCloudMemoryTokenStore()
            tokens.saveToken(String(repeating: "t", count: 43), for: f.session.endpoint)
            let client = SelectiveRemoteCloudAccessClient(client: .init(tokenStore: tokens,
                dataLoader: { try await transport.load($0) }))
            let model = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: client, session: f.session)
            let oldLoad = Task { await model.load() }
            await transport.waitUntilHeld()
            model.invalidateSession()
            let count = await transport.requests
            await transport.release(reply, statusCode: failure ? 503 : 200)
            await oldLoad.value
            #expect(model.context == nil && model.resource == nil && model.grants.isEmpty && model.who.isEmpty)
            #expect(model.errorMessage == nil && !model.busy && !model.canCommit)
            await model.load()
            #expect(await transport.requests == count)
        }
    }

    @Test @MainActor func accountChangeRejectsDelayedCommitReceipt() async throws {
        let f = try AccessFixture(), grantID = UUID()
        let fallback = try AccessFixtureTransport(f.loadReplies(previews: [f.preview()]))
        let transport = AccessHeldReplyTransport(fallback: fallback, heldPath: f.base + "/access-commit")
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "t", count: 43), for: f.session.endpoint)
        let client = SelectiveRemoteCloudAccessClient(client: .init(tokenStore: tokens,
            dataLoader: { try await transport.load($0) }))
        let model = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: client, session: f.session)
        await model.load()
        model.setSelection([.init(kind: .user, id: UUID(), name: "Account A")])
        await model.previewSelection()
        #expect(model.canCommit)
        let oldCommit = Task { await model.commit() }
        await transport.waitUntilHeld()
        model.invalidateSession()
        let receipt = try f.data(["applied": 1,
            "grants": [["type": "GRANT_CREATE", "grantID": grantID.canonicalCloudString]],
            "notificationCandidates": [],
            "counts": ["pairs": 1, "widened": 1, "lost": 0]])
        await transport.release(receipt)
        #expect(await oldCommit.value == nil)
        #expect(model.context == nil && model.preview == nil && !model.committed)
    }
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
        let grant = CloudAccessGrant(id: UUID(), principal_kind: .user, principal_id: UUID(), target_kind: .resource, target_id: credential, permission_mask: 1, version: try .init(7))
        var grantRow = f.grantWire(id: grant.id, version: 7); grantRow["target_id"] = credential.canonicalCloudString; grantRow["principal_id"] = grant.principal_id.canonicalCloudString
        routes[f.base + "/access-grants"] = [(try f.data(["rows": [grantRow], "nextCursor": NSNull()]), 200)]
        let t = AccessFixtureTransport(routes); let model = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        await model.load()
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
        var routes = try f.loadReplies(previews: [f.preview(details: [detail])])
        var grantRow = f.grantWire(id: grant, version: 1); grantRow["principal_id"] = subject.canonicalCloudString
        routes[f.base + "/access-grants"] = [(try f.data(["rows": [grantRow], "nextCursor": NSNull()]), 200)]
        let t = AccessFixtureTransport(routes)
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

private extension AccessFixture {
    func impact(subject: UUID = UUID(), resource: UUID = UUID()) -> [String: Any] {
        let effective: [String: Any] = ["policyEffective": ["policyAllowed": false, "policyMask": 0, "paths": [], "blockedReasons": ["POLICY_DENIED"]]]
        return ["vaultID": reference.vaultID.canonicalCloudString, "resourceID": resource.canonicalCloudString, "subjectUserID": subject.canonicalCloudString, "before": effective, "after": effective, "gainedMask": 0, "lostMask": 0]
    }
    func grantWire(id: UUID, version: Int, mask: Int = 1) -> [String: Any] {
        ["id": id.canonicalCloudString, "principal_kind": "USER", "principal_id": UUID().canonicalCloudString, "target_kind": "RESOURCE", "target_id": reference.resourceID.canonicalCloudString, "permission_mask": mask, "version": String(version)]
    }
}
extension CloudAccessTests {
    @Test @MainActor func incompleteDuplicateAndChangedCountsCannotCommit() async throws {
        let f = try AccessFixture(), one = f.impact(), two = f.impact()
        let cases: [[[String: Any]]] = [
            [f.preview(pairs: 100)],
            [f.preview(details: [one, one], pairs: 2)],
            [f.preview(cursor: "1", details: [one], pairs: 2), f.preview(details: [one], pairs: 2)],
            [f.preview(cursor: "1", details: [one], pairs: 2), f.preview(details: [two], pairs: 3)],
            [f.preview(cursor: "1", details: [one], pairs: 2), f.preview(pairs: 2)]
        ]
        let capture = ProcessInfo.processInfo.environment["SR_CAPTURE_ACCESS_MATRIX"]
        if let capture { try FileManager.default.createDirectory(atPath: capture, withIntermediateDirectories: true) }
        let languageKey = "SelectiveRemote.applicationLanguage.v1"
        let priorLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("english", forKey: languageKey)
        defer {
            if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
        }
        for (index, pages) in cases.enumerated() {
            let t = try AccessFixtureTransport(f.loadReplies(previews: pages))
            let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
            await m.load(); m.setSelection([.init(kind: .user, id: UUID(), name: "Member")]); await m.previewSelection()
            if let capture, m.preview?.nextCursor != nil {
                let labels = try await renderedAccessText(m, output: URL(fileURLWithPath: capture).appending(path: "invalid-preview-\(index)-pending.png"))
                #expect(labels.joined(separator: " ").contains("Next impact page"))
                #expect(!labels.joined(separator: " ").contains("Confirm"))
                try labels.joined(separator: "\n").write(to: URL(fileURLWithPath: capture).appending(path: "invalid-preview-\(index)-pending-ocr.txt"), atomically: true, encoding: .utf8)
            }
            if m.preview?.nextCursor != nil { await m.nextPreviewPage() }
            #expect(!m.canCommit); #expect(m.preview == nil)
            if let capture {
                let labels = try await renderedAccessText(m, output: URL(fileURLWithPath: capture).appending(path: "invalid-preview-\(index)-terminal.png"))
                #expect(labels.joined(separator: " ").contains("Preview change"))
                #expect(!labels.joined(separator: " ").contains("Confirm"))
                try labels.joined(separator: "\n").write(to: URL(fileURLWithPath: capture).appending(path: "invalid-preview-\(index)-terminal-ocr.txt"), atomically: true, encoding: .utf8)
                #expect(await t.captured().filter { $0.url?.path == f.base + "/access-commit" }.isEmpty)
            }
        }
    }
    @Test @MainActor func zeroPairGroupGrantsStillPageAndValidateExactTerminalTotal() async throws {
        let f = try AccessFixture()
        let grants: [[String: Any]] = (0..<51).map { _ in ["grantID": UUID().canonicalCloudString, "vaultID": f.reference.vaultID.canonicalCloudString, "targetKind": "RESOURCE", "targetID": UUID().canonicalCloudString, "permissionMask": 1, "version": 1] }
        func page(_ rows: [[String: Any]], cursor: String?) -> [String: Any] {
            ["token": "synthetic-preview", "snapshotID": String(repeating: "a", count: 64), "details": [], "affectedGrants": rows, "counts": ["pairs": 0, "widened": 0, "lost": 0, "affectedGrants": 51], "nextCursor": cursor.map { $0 as Any } ?? NSNull()]
        }
        for terminal in [Array(grants.suffix(1)), [], Array(grants.prefix(1))] {
            var routes = try f.loadReplies()
            routes[f.base + "/access-group-preview"] = [(try f.data(page(Array(grants.prefix(50)), cursor: "50")), 200), (try f.data(page(terminal, cursor: nil)), 200)]
            let t = AccessFixtureTransport(routes); let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
            await m.load(); await m.prepare(.init(group: .init(type: "GROUP_DELETE", fields: ["groupID": .id(UUID()), "expectedVersion": .number(1)])))
            #expect(!m.canCommit); #expect(m.impacts.isEmpty); #expect(m.affectedGrants.count == 50)
            await m.nextPreviewPage()
            if terminal.first?["grantID"] as? String == grants.last?["grantID"] as? String { #expect(m.canCommit); #expect(m.affectedGrants.count == 51) }
            else { #expect(!m.canCommit); #expect(m.preview == nil) }
        }
    }
    @Test @MainActor func committedChangeAndRevokeRefreshPolicyAndRejectOldGrantVersion() async throws {
        for revoke in [false, true] {
            let f = try AccessFixture(), grantID = UUID(), subject = UUID(), device = UUID()
            let old = f.grantWire(id: grantID, version: 1)
            let updated = f.grantWire(id: grantID, version: 2, mask: 5)
            var routes = try f.loadReplies(previews: [f.preview()])
            routes[f.base + "/access-grants"] = [(try f.data(["rows": [old], "nextCursor": NSNull()]), 200), (try f.data(["rows": revoke ? [] : [updated], "nextCursor": NSNull()]), 200)]
            let policyBefore: [String: Any] = ["policyAllowed": true, "policyMask": 1, "paths": [], "blockedReasons": []]
            let policyAfter: [String: Any] = ["policyAllowed": !revoke, "policyMask": revoke ? 0 : 5, "paths": [], "blockedReasons": []]
            routes[f.base + "/who-has-access/" + f.reference.resourceID.canonicalCloudString] = [(try f.data(["rows": [["userID": subject.canonicalCloudString, "policyEffective": policyBefore]], "nextCursor": NSNull()]), 200), (try f.data(["rows": revoke ? [] : [["userID": subject.canonicalCloudString, "policyEffective": policyAfter]], "nextCursor": NSNull()]), 200)]
            routes[f.base + "/access-devices"] = [(try f.data(["rows": [["id": device.canonicalCloudString, "name": "Synthetic", "platform": "mac", "admitted": true]], "nextCursor": NSNull()]), 200)]
            let usability: [String: Any] = ["deviceID": device.canonicalCloudString, "effectiveUsable": "NO", "cryptoAvailable": "NO", "cryptoAvailableByPermission": [:], "effectiveUsableByPermission": [:], "blockedReasons": ["KEY_UNAVAILABLE"]]
            routes[f.base + "/effective-access/" + f.reference.resourceID.canonicalCloudString] = [(try f.data(["policyEffective": policyBefore, "deviceUsability": usability]), 200)]
            routes[f.base + "/access-commit"] = [(try f.data(["applied": 1, "grants": [["type": revoke ? "GRANT_REVOKE" : "GRANT_CHANGE", "grantID": grantID.canonicalCloudString]], "notificationCandidates": [], "counts": ["pairs": 0, "widened": 0, "lost": 0]]), 200)]
            let t = AccessFixtureTransport(routes); let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
            await m.load(); let oldGrant = m.grants[0]
            await m.selectSubject(subject); await m.selectDevice(device); #expect(m.effective != nil)
            if revoke { await m.revoke([oldGrant]) } else { await m.edit(oldGrant); m.setMask(5); await m.previewSelection() }
            #expect(await m.commit() != nil); #expect(m.committed); #expect(m.editingGrant == nil); #expect(m.selection.isEmpty)
            #expect(m.effective == nil); #expect(m.subjectUserID == nil); #expect(m.subjectDeviceID == nil)
            #expect(m.who.first?.policyEffective.policyMask == (revoke ? nil : 5))
            #expect(m.grants.first?.version.value == (revoke ? nil : 2))
            await m.edit(oldGrant); #expect(m.editingGrant == nil)
            let beforeStaleRevoke = await t.captured().filter { $0.url!.path.hasSuffix("access-preview") }.count
            await m.revoke([oldGrant]); #expect(m.preview == nil)
            #expect(await t.captured().filter { $0.url!.path.hasSuffix("access-preview") }.count == beforeStaleRevoke)
            if !revoke { await m.edit(m.grants[0]); #expect(m.editingGrant?.version.value == 2) }
        }
    }
    @Test @MainActor func successfulReceiptSurvivesRefreshFailureAndFurtherWritesWait() async throws {
        let f = try AccessFixture(), grantID = UUID()
        var routes = try f.loadReplies(previews: [f.preview()])
        routes[f.base + "/access-context"] = [(try f.data(f.context), 200), (try f.data(["error": "access_request_failed"]), 503)]
        routes[f.base + "/access-commit"] = [(try f.data(["applied": 1, "grants": [["type": "GRANT_CREATE", "grantID": grantID.canonicalCloudString]], "notificationCandidates": [["userID": UUID().canonicalCloudString, "resourceID": f.reference.resourceID.canonicalCloudString, "gainedMask": 1, "lostMask": 0]], "counts": ["pairs": 1, "widened": 1, "lost": 0]]), 200)]
        let t = AccessFixtureTransport(routes); let m = SelectiveRemoteCloudAccessCoordinator(reference: f.reference, client: f.client(t), session: f.session)
        await m.load(); m.setSelection([.init(kind: .user, id: UUID(), name: "Member")]); await m.previewSelection()
        let receipt = await m.commit()
        #expect(receipt?.notificationCandidates.count == 1); #expect(m.committed)
        #expect(!m.canMutate); #expect(!m.canCommit); #expect(m.preview == nil); #expect(m.errorMessage != nil)
        #expect(m.grants.isEmpty); #expect(m.who.isEmpty); #expect(m.effective == nil)
        #expect(await m.commit() == nil)
        #expect(await t.captured().filter { $0.url!.path.hasSuffix("access-commit") }.count == 1)
    }
}
