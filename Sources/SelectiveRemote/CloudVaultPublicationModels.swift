import AppKit
import CryptoKit
import Foundation
import SwiftUI

struct SelectiveRemotePublishedPart: Codable, Equatable, Sendable {
    let resourceID: UUID
    let kind: CloudAccessKind
    let part: SelectiveRemoteResourcePart
    let parentFolderID: UUID?
    /// Original ordinary JSON preserves vector clocks, ISO timestamps and fractional source numbers.
    let plaintext: Data
}
struct SelectiveRemotePublicationCache: Codable, Equatable, Sendable {
    let scope: SelectiveRemotePublicationScope
    let teamName: String
    let vaultName: String
    let role: SelectiveRemoteCloudTeamRole
    let header: SelectiveRemoteJSONValue
    let headerHash: String
    let subject: SelectiveRemoteJSONValue
    let inventory: SelectiveRemoteJSONValue
    let publisher: SelectiveRemoteJSONValue
    let descriptors: [SelectiveRemoteJSONValue]
    let readerPublicKey: SelectiveRemoteTeamDevicePublicKey
    let readerKeyVersion: Int
    let parts: [SelectiveRemotePublishedPart]
    var stale: Bool = false
}

enum SelectiveRemotePublicationPartDecoder {
    /// Only the authenticated descriptor supplies runtime identity. Source JSON stays byte-for-byte in plaintext.
    static func runtimeRecord(_ original: SelectiveRemoteJSONValue, resourceID: UUID) throws -> SelectiveRemoteVaultRecord {
        var projected = try original.publicationObject()
        projected["id"] = .string(resourceID.canonicalCloudString)
        return try JSONDecoder().decode(SelectiveRemoteVaultRecord.self, from: JSONEncoder().encode(SelectiveRemoteJSONValue.object(projected)))
    }
    static func decode(_ plaintext: Data, descriptor: SelectiveRemoteJSONValue, header: SelectiveRemoteJSONValue) throws -> SelectiveRemotePublishedPart {
        guard plaintext.count <= 1024 * 1024 else { throw SelectiveRemotePublicationError.invalid }
        let object = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: plaintext).publicationObject()
        let d = try SelectiveRemoteVaultPublicationV1.descriptorPayload(descriptor)
        let h = try SelectiveRemoteVaultPublicationV1.headerPayload(header)
        guard let rawLink = object["link"] else { throw SelectiveRemotePublicationError.scope }
        let link = try rawLink.publicationObject(["teamID", "vaultID", "generationID", "resourceID", "kind", "part"])
        guard ["teamID", "vaultID", "generationID"].allSatisfy({ link[$0] == h[$0] }),
              ["resourceID", "kind", "part"].allSatisfy({ link[$0] == d[$0] }) else { throw SelectiveRemotePublicationError.scope }
        let kind = try CloudAccessKind(rawValue: d["kind"]!.publicationString())!
        let part = try SelectiveRemoteResourcePart(rawValue: d["part"]!.publicationString())!
        if kind == .credential && part == .metadata {
            guard Set(object.keys) == ["link", "metadata"], let metadata = object["metadata"] else { throw SelectiveRemotePublicationError.invalid }
            let values = try metadata.publicationObject()
            guard Set(values.keys).isSubset(of: ["title", "username", "kind"]),
                  let title = values["title"], try !title.publicationString().isEmpty,
                  values.values.allSatisfy({ if case .string = $0 { true } else { false } }) else { throw SelectiveRemotePublicationError.invalid }
        } else if kind == .folder {
            guard Set(object.keys) == ["link", "folder"], let folder = object["folder"] else { throw SelectiveRemotePublicationError.invalid }
            let values = try folder.publicationObject(["type", "path", "component"])
            let type = try values["type"]!.publicationString(), path = try values["path"]!.publicationString(), component = try values["component"]!.publicationString()
            let components = try SelectiveRemoteLegacyResourceMapper.folderComponents(path)
            guard ["host", "snippet"].contains(type), !component.contains("/"),
                  components.last.map({ Data($0.utf8) }) == Data(component.utf8) else { throw SelectiveRemotePublicationError.invalid }
        } else {
            guard Set(object.keys) == ["link", "record"], let value = object["record"] else { throw SelectiveRemotePublicationError.invalid }
            let record = try runtimeRecord(value, resourceID: UUID(uuidString: d["resourceID"]!.publicationString())!)
            let expected: [CloudAccessKind: SelectiveRemoteVaultRecordType] = [.host: .host, .credential: .credential, .snippet: .snippet, .forwarding: .forwarding]
            guard record.type == expected[kind], case let .object(data) = record.data else { throw SelectiveRemotePublicationError.invalid }
            if kind == .credential { guard let secret = data["secret"], try !secret.publicationString().isEmpty else { throw SelectiveRemotePublicationError.invalid } }
        }
        return .init(resourceID: UUID(uuidString: try d["resourceID"]!.publicationString())!, kind: kind, part: part,
            parentFolderID: d["parentFolderID"] == .null ? nil : UUID(uuidString: try d["parentFolderID"]!.publicationString()), plaintext: plaintext)
    }
}

@MainActor
final class SelectiveRemotePublicationPresentation: ObservableObject {
    static let shared = SelectiveRemotePublicationPresentation()
    @Published private(set) var caches: [SelectiveRemotePublicationCache] = []
    @Published private(set) var secrets: [String: String] = [:]
    private var sessions: [String: SelectiveRemotePublicationSession] = [:]
    private var readers: [String: SelectiveRemoteVaultPublicationCoordinator] = [:]
    func detach(scope: SelectiveRemotePublicationScope, expectedSession: SelectiveRemotePublicationSession? = nil) {
        if let expectedSession, sessions[scope.key]?.sameAuthorization(as: expectedSession) != true { return }
        caches.removeAll { $0.scope == scope }; secrets = secrets.filter { !$0.key.hasPrefix(scope.key) }; sessions.removeValue(forKey: scope.key); readers.removeValue(forKey: scope.key); PublishedAccessWindows.closeInvalid(); SelectiveRemotePublisherVerificationSheet.closeAll()
        SelectiveRemoteTeamHostStore.shared.removeVault(teamID: scope.teamID, vaultID: scope.vaultID)
        SelectiveRemoteTeamSnippetStore.shared.removeVault(teamID: scope.teamID, vaultID: scope.vaultID)
        SelectiveRemoteTeamCredentialStore.shared.removeVault(teamID: scope.teamID, vaultID: scope.vaultID)
    }
    func clear() {
        sessions.values.forEach { $0.invalidate() }; caches = []; secrets = [:]; sessions = [:]; readers = [:]; PublishedAccessWindows.closeInvalid(); SelectiveRemotePublisherVerificationSheet.closeAll()
        SelectiveRemoteTeamHostStore.shared.clear(); SelectiveRemoteTeamSnippetStore.shared.clear(); SelectiveRemoteTeamCredentialStore.shared.clear()
    }
    func clearInvalidSessions(endpoint: URL? = nil) {
        for (key, session) in sessions where (endpoint == nil || session.endpoint == endpoint) && (try? session.check()) == nil {
            if let cache = caches.first(where: { $0.scope.key == key }) { detach(scope: cache.scope, expectedSession: session) }
            else { sessions.removeValue(forKey: key); readers.removeValue(forKey: key) }
        }
        SelectiveRemotePublisherVerificationSheet.closeInvalid()
    }
    func bind(reader: SelectiveRemoteVaultPublicationCoordinator, session: SelectiveRemotePublicationSession, scope: SelectiveRemotePublicationScope) throws {
        try session.check(); sessions[scope.key] = session; readers[scope.key] = reader
    }
    func replace(with snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot]) {
        caches = snapshots.compactMap(\.publication).filter { cache in (try? sessions[cache.scope.key]?.check()) != nil }
        secrets = [:]
    }
    func valid(_ reference: SelectiveRemotePublishedModelReference) -> Bool {
        guard let session = sessions[reference.scope.key], (try? session.check()) != nil,
              let cache = caches.first(where: { $0.scope == reference.scope }), cache.headerHash == reference.headerHash else { return false }
        return !cache.stale && !reference.stale
    }
    func isPublished(teamID: UUID, vaultID: UUID) -> Bool { caches.contains { $0.scope.teamID == teamID && $0.scope.vaultID == vaultID } }
    func canReveal(_ reference: SelectiveRemotePublishedModelReference) -> Bool {
        guard valid(reference), let cache = caches.first(where: { $0.scope == reference.scope }) else { return false }
        return cache.descriptors.contains { d in
            guard let p = try? SelectiveRemoteVaultPublicationV1.descriptorPayload(d) else { return false }
            return p["resourceID"] == .string(reference.resourceID.canonicalCloudString) && p["part"] == .string("SECRET")
        }
    }
    func secret(_ reference: SelectiveRemotePublishedModelReference) -> String? { valid(reference) ? secrets[reference.key] : nil }
    func conceal(_ reference: SelectiveRemotePublishedModelReference) { secrets.removeValue(forKey: reference.key) }
    func reveal(_ reference: SelectiveRemotePublishedModelReference) async throws -> String {
        guard canReveal(reference), let reader = readers[reference.scope.key] else { throw SelectiveRemotePublicationError.subject }
        let result = try await reader.reveal(resourceID: reference.resourceID)
        guard valid(reference) else { throw CancellationError() }
        secrets[reference.key] = result
        return result
    }
    func hostCredentials(_ host: SelectiveRemoteTeamHost) async throws -> SelectiveRemoteTeamHostCredentials {
        guard let reference = host.publication, valid(reference), let reader = readers[reference.scope.key],
              let cache = caches.first(where: { $0.scope == reference.scope }),
              let hostPart = cache.parts.first(where: { $0.resourceID == reference.resourceID && $0.kind == .host }),
              let original = try cache.payload(hostPart)["record"] else { throw SelectiveRemotePublicationError.subject }
        // Telnet and serial transports have no password input and must not read unrelated SECRET parts.
        guard [.rdp, .ssh].contains(host.profile.connectionType) else { return .empty }
        guard let sourceID = try original.publicationObject()["id"]?.publicationString() else { throw SelectiveRemotePublicationError.subject }
        let matches = try cache.parts.filter { part in
            guard part.kind == .host, let record = try cache.payload(part)["record"]?.publicationObject(),
                  let id = try record["id"]?.publicationString() else { return false }
            return Data(id.utf8) == Data(sourceID.utf8)
        }
        guard matches.count == 1 else { throw SelectiveRemotePublicationError.scope }
        var result = SelectiveRemoteTeamHostCredentials.empty
        for part in cache.parts where part.kind == .credential && part.part == .metadata {
            let metadata = try cache.payload(part)["metadata"]!.publicationObject()
            let requiredKind = host.profile.connectionType == .rdp ? "rdp" : "ssh"
            guard let kind = try metadata["kind"]?.publicationString(), kind == requiredKind || (kind == "gateway" && host.profile.connectionType == .rdp && !host.profile.gatewayHost.isEmpty) else { continue }
            let credentialReference = try cache.reference(part)
            guard canReveal(credentialReference) else { continue }
            let record = try await reader.secretRecord(resourceID: part.resourceID)
            guard valid(reference) else { throw CancellationError() }
            let data = try record.data.publicationObject()
            guard let credentialSource = try data["sourceID"]?.publicationString(), Data(credentialSource.utf8) == Data(sourceID.utf8) else { continue }
            guard data["kind"] == .string(kind) else { throw SelectiveRemotePublicationError.scope }
            let secret = try data["secret"]!.publicationString()
            if kind == "gateway" { guard result.gatewayPassword == nil else { throw SelectiveRemotePublicationError.invalid }; result.gatewayPassword = secret }
            else { guard result.password == nil else { throw SelectiveRemotePublicationError.invalid }; result.password = secret }
        }
        let passwordRequired = [.rdp, .ssh].contains(host.profile.connectionType)
        guard !passwordRequired || result.password != nil else { throw SelectiveRemotePublicationError.subject }
        guard valid(reference) else { throw CancellationError() }
        return result
    }
    func connectionEnabled(_ host: SelectiveRemoteTeamHost, temporaryPassword: String) -> Bool {
        guard let reference = host.publication else { return host.profile.connectionType != .rdp || !temporaryPassword.isEmpty }
        guard valid(reference) else { return false }
        guard [.rdp, .ssh].contains(host.profile.connectionType) else { return true }
        let required = host.profile.connectionType == .rdp ? "rdp" : "ssh"
        return caches.first(where: { $0.scope == reference.scope })?.parts.contains { part in
            guard part.kind == .credential, part.part == .metadata,
                  let cache = caches.first(where: { $0.scope == reference.scope }),
                  let metadata = try? cache.payload(part)["metadata"]?.publicationObject(),
                  metadata["kind"] == .string(required), let credential = try? cache.reference(part) else { return false }
            return canReveal(credential)
        } == true
    }
    func performHostConnection(_ host: SelectiveRemoteTeamHost, action: (SelectiveRemoteTeamHostCredentials) -> Void) async throws {
        let credentials = try await hostCredentials(host)
        guard let reference = host.publication, valid(reference) else { throw CancellationError() }
        action(credentials)
    }
    func folders(type: String? = nil) -> [SelectiveRemotePublishedFolder] {
        caches.flatMap { cache in (try? cache.folders().filter { type == nil || $0.type == type }) ?? [] }
    }
    func verifiedParts(reference: SelectiveRemoteCloudAccessReference, accountID: UUID?, deviceID: UUID?) -> [SelectiveRemoteResourcePart] {
        guard let cache = caches.first(where: { $0.scope.teamID == reference.teamID && $0.scope.vaultID == reference.vaultID && $0.scope.accountID == accountID && $0.scope.deviceID == deviceID }), !cache.stale else { return [] }
        return cache.parts.compactMap { part in
            guard part.resourceID == reference.resourceID, part.kind == reference.kind, let verified = try? cache.reference(part), valid(verified) else { return nil }
            return part.part
        }
    }
    func verificationReference(reference: SelectiveRemoteCloudAccessReference) -> SelectiveRemotePublishedModelReference? {
        for cache in caches where cache.scope.teamID == reference.teamID && cache.scope.vaultID == reference.vaultID {
            for part in cache.parts where part.resourceID == reference.resourceID && part.kind == reference.kind {
                if let verified = try? cache.reference(part), valid(verified) { return verified }
            }
        }
        return nil
    }
    var forwardings: [SelectiveRemotePublishedForwarding] { caches.flatMap { (try? $0.forwardings()) ?? [] } }
    static var readOnlyMessage: String { CloudAccessLocalization.text("Изменение опубликованных объектов требует новой публикации Vault. Сейчас доступен просмотр.", "Changing published items requires a new Vault publication. This version provides read-only access.") }
    func showReadOnly() {
        let alert = NSAlert(); alert.messageText = Self.readOnlyMessage; alert.addButton(withTitle: CloudAccessLocalization.text("Понятно", "OK")); alert.runModal()
    }
}

struct SelectiveRemotePublishedModelReference: Equatable, Sendable {
    let scope: SelectiveRemotePublicationScope
    let resourceID: UUID
    let kind: CloudAccessKind
    let generationID: String
    let headerHash: String
    let part: SelectiveRemoteResourcePart
    let stale: Bool
    func access(displayName: String) throws -> SelectiveRemoteCloudAccessReference {
        guard !stale else { throw SelectiveRemotePublicationError.subject }
        return try .init(teamID: scope.teamID, vaultID: scope.vaultID, resourceID: resourceID, kind: kind, displayName: displayName)
    }
    var key: String { scope.key + "\n" + resourceID.canonicalCloudString }
}

extension SelectiveRemotePublicationCache {
    func payload(_ part: SelectiveRemotePublishedPart) throws -> [String: SelectiveRemoteJSONValue] {
        try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: part.plaintext).publicationObject()
    }
    func reference(_ part: SelectiveRemotePublishedPart) throws -> SelectiveRemotePublishedModelReference {
        .init(scope: scope, resourceID: part.resourceID, kind: part.kind,
            generationID: try SelectiveRemoteVaultPublicationV1.headerPayload(header)["generationID"]!.publicationString(),
            headerHash: headerHash, part: part.part, stale: stale)
    }
    func reference(recordID: UUID, kind: CloudAccessKind) throws -> SelectiveRemotePublishedModelReference? {
        for part in parts where part.kind == kind {
            if part.resourceID == recordID {
                return try reference(part)
            }
        }
        return nil
    }
    func folderPath(parent: UUID?, type: String) throws -> String {
        var current = parent, visited = Set<UUID>(), components: [String] = []
        while let id = current {
            guard visited.insert(id).inserted else { throw SelectiveRemotePublicationError.scope }
            guard let folder = parts.first(where: { $0.resourceID == id && $0.kind == .folder }) else { break }
            let f = try payload(folder)["folder"]!.publicationObject()
            guard f["type"] == .string(type) else { throw SelectiveRemotePublicationError.scope }
            let component = try f["component"]!.publicationString()
            guard visited.count <= 32, try SelectiveRemoteLegacyResourceMapper.folderComponents(component).count == 1 else { throw SelectiveRemotePublicationError.invalid }
            components.insert(component, at: 0); current = folder.parentFolderID
        }
        return components.joined(separator: "/")
    }
    func materializedSnapshot() throws -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        var records: [SelectiveRemoteVaultRecord] = []
        for part in parts where part.kind == .host || part.kind == .snippet {
            guard let value = try payload(part)["record"] else { throw SelectiveRemotePublicationError.invalid }
            let record = try SelectiveRemotePublicationPartDecoder.runtimeRecord(value, resourceID: part.resourceID)
            var data = try record.data.publicationObject()
            let folder = try folderPath(parent: part.parentFolderID, type: part.kind == .host ? "host" : "snippet")
            data["folder"] = .string(folder)
            if part.kind == .host, let encoded = data["profile"], let bytes = Data(selectiveRemoteBase64URL: try encoded.publicationString()) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var profile = try decoder.decode(ConnectionProfile.self, from: bytes)
                let source = try value.publicationObject()["id"]?.publicationString()
                guard source.flatMap(UUID.init(uuidString:)) == profile.id else { throw SelectiveRemotePublicationError.scope }
                profile.group = folder; profile.id = part.resourceID
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                data["profile"] = .string(try encoder.encode(profile).selectiveRemoteBase64URL)
            }
            records.append(try .init(id: record.id, type: record.type, version: record.version, modifiedAt: record.modifiedAt, data: .object(data)))
        }
        let sequence = try SelectiveRemoteVaultPublicationV1.headerPayload(header)["sequence"]!.publicationInteger()
        var snapshot = SelectiveRemoteTeamVaultMaterializedSnapshot(teamID: scope.teamID, teamName: teamName, role: role, vaultID: scope.vaultID, vaultName: vaultName, revision: sequence, keyGeneration: sequence, payload: try SelectiveRemoteVaultDocument(records: records).encoded())
        snapshot.publication = self
        _ = try SelectiveRemoteTeamHostMaterializer.materialize(snapshot)
        _ = try SelectiveRemoteTeamSnippetMaterializer.materialize(snapshot)
        _ = try credentials()
        _ = try forwardings()
        _ = try folders()
        return snapshot
    }
    func credentials() throws -> [SelectiveRemoteTeamCredential] {
        try parts.filter { $0.kind == .credential && $0.part == .metadata }.map { part in
            let data = try payload(part)["metadata"]!.publicationObject()
            let title = try data["title"]!.publicationString(), username = try data["username"]?.publicationString() ?? ""
            guard !title.isEmpty, title.count <= 120, username.count <= 256,
                  !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SelectiveRemotePublicationError.invalid }
            let sequence = try SelectiveRemoteVaultPublicationV1.headerPayload(header)["sequence"]!.publicationInteger()
            return .init(id: SelectiveRemoteTeamHostMaterializer.scopedID(teamID: scope.teamID, vaultID: scope.vaultID, recordID: part.resourceID), recordID: part.resourceID,
                teamID: scope.teamID, teamName: teamName, role: role, vaultID: scope.vaultID, vaultName: vaultName,
                revision: sequence, keyGeneration: sequence, modifiedDate: .distantPast, title: title, username: username, secret: nil,
                folder: "", tags: [], sourceHostID: nil, sourceHostTitle: nil, kind: data["kind"].flatMap { try? KeychainCredentialKind(rawValue: $0.publicationString()) }, publication: try reference(part))
        }
    }
    func forwardings() throws -> [SelectiveRemotePublishedForwarding] {
        try parts.filter { $0.kind == .forwarding }.map { part in
            let record = try SelectiveRemotePublicationPartDecoder.runtimeRecord(payload(part)["record"]!, resourceID: part.resourceID)
            let data = try record.data.publicationObject()
            guard let title = data["title"], try !title.publicationString().isEmpty else { throw SelectiveRemotePublicationError.invalid }
            return .init(reference: try reference(part), record: record, title: try title.publicationString())
        }
    }
}

struct SelectiveRemotePublishedForwarding: Identifiable, Equatable, Sendable {
    let reference: SelectiveRemotePublishedModelReference
    let record: SelectiveRemoteVaultRecord
    let title: String
    var id: String { reference.key }
}

struct SelectiveRemotePublishedFolder: Identifiable, Equatable, Sendable {
    let reference: SelectiveRemotePublishedModelReference
    let path: String
    let component: String
    let type: String
    let vaultName: String
    var id: String { reference.key }
}

struct SelectiveRemotePublishedFolderStrip: View {
    @ObservedObject private var publication = SelectiveRemotePublicationPresentation.shared
    let type: String
    let selectedVaultKeys: Set<String>
    private var folders: [SelectiveRemotePublishedFolder] {
        publication.folders(type: type).filter { selectedVaultKeys.contains($0.reference.scope.teamID.canonicalCloudString + "/" + $0.reference.scope.vaultID.canonicalCloudString) }
    }
    private var caches: [SelectiveRemotePublicationCache] {
        publication.caches.filter { selectedVaultKeys.contains($0.scope.teamID.canonicalCloudString + "/" + $0.scope.vaultID.canonicalCloudString) }
    }
    var body: some View {
        if !caches.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(caches, id: \.scope.key) { cache in
                    Text(cache.vaultName + " · " + (cache.stale ? CloudAccessLocalization.text("проверенный кэш офлайн · секреты и доступ недоступны", "verified offline cache · secrets and access unavailable") : CloudAccessLocalization.text("публикация проверена · только просмотр", "publication verified · read-only")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(folders) { folder in
                            Button {
                                AccessResourceEntry.showPublished(folder.reference, title: folder.path, kind: .folder)
                            } label: {
                                Label(folder.vaultName + " · " + folder.path + (folder.reference.stale ? " · " + CloudAccessLocalization.text("кэш офлайн", "offline cache") : ""), systemImage: "folder")
                            }.disabled(!publication.valid(folder.reference))
                                .accessibilityLabel(CloudAccessLocalization.text("Доступ к папке", "Folder access") + " " + folder.path)
                        }
                    }
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
extension SelectiveRemotePublicationCache {
    func folders() throws -> [SelectiveRemotePublishedFolder] {
        try parts.filter { $0.kind == .folder }.map { part in
            let data = try payload(part)["folder"]!.publicationObject()
            let type = try data["type"]!.publicationString()
            return .init(reference: try reference(part), path: try folderPath(parent: part.resourceID, type: type), component: try data["component"]!.publicationString(), type: type, vaultName: vaultName)
        }
    }
}
