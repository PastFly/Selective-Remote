import Foundation

/// Intent construction uses verified linked plaintext and explicit resource IDs. Source records, clocks and secret fields are retained.
enum SelectiveRemoteWholePublicationEditing {
    enum Intent { case content(title: String, body: String?); case move(parent: UUID?) }
    struct Draft: Sendable { let vault: SelectiveRemoteJSONValue; let changedParts: [String: Data] }
    struct Principal: Identifiable, Sendable {
        let id: UUID; let kind: String; let name: String; let membershipID: UUID?; let epoch: Int?
        var key: String { kind + "/" + id.canonicalCloudString }
    }
    static func encoded(_ value: SelectiveRemoteJSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    static func payload(_ part: SelectiveRemotePublishedPart, reference: SelectiveRemotePublishedModelReference) throws -> [String: SelectiveRemoteJSONValue] {
        let payload = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: part.plaintext).publicationObject()
        guard let linkJSON = payload["link"] else { throw SelectiveRemoteWholePublicationError.scope }
        let link = try linkJSON.publicationObject(["teamID", "vaultID", "generationID", "resourceID", "kind", "part"])
        guard link["teamID"] == .string(reference.scope.teamID.canonicalCloudString), link["vaultID"] == .string(reference.scope.vaultID.canonicalCloudString),
              link["generationID"] == .string(reference.generationID), link["resourceID"] == .string(part.resourceID.canonicalCloudString),
              link["kind"] == .string(part.kind.rawValue), link["part"] == .string(part.part.rawValue) else { throw SelectiveRemoteWholePublicationError.scope }
        return payload
    }
    static func draft(vault: SelectiveRemoteJSONValue, reference: SelectiveRemotePublishedModelReference, parts: [SelectiveRemotePublishedPart], intent: Intent) throws -> Draft {
        guard !reference.stale, reference.part == .general, [.host, .snippet, .folder].contains(reference.kind) else { throw SelectiveRemoteWholePublicationError.scope }
        var v = try vault.publicationObject(["vaultID", "resources", "policy", "contentChanges", "custodianDeviceIDs"])
        guard v["vaultID"] == .string(reference.scope.vaultID.canonicalCloudString) else { throw SelectiveRemoteWholePublicationError.scope }
        var resources = try v["resources"]!.publicationArray().map { try $0.publicationObject(["id", "kind", "parentFolderID", "sourceOrdinal"]) }
        guard let selected = resources.firstIndex(where: { $0["id"] == .string(reference.resourceID.canonicalCloudString) }), resources[selected]["kind"] == .string(reference.kind.rawValue),
              let source = parts.first(where: { $0.resourceID == reference.resourceID && $0.kind == reference.kind && $0.part == .general }) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        var payloads: [UUID: [String: SelectiveRemoteJSONValue]] = [:]
        func partPayload(_ id: UUID) throws -> [String: SelectiveRemoteJSONValue] {
            if let p = payloads[id] { return p }
            guard let part = parts.first(where: { $0.resourceID == id && $0.part == .general }) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
            let p = try payload(part, reference: reference); payloads[id] = p; return p
        }
        var changes: [UUID: [String: SelectiveRemoteJSONValue]] = [:]
        func recordChange(_ id: UUID, title: String? = nil, body: String? = nil, folder: String? = nil) throws {
            var p = try partPayload(id)
            guard let raw = p["record"] else { throw SelectiveRemoteWholePublicationError.scope }
            var record = try raw.publicationObject(); guard let rawData = record["data"] else { throw SelectiveRemoteWholePublicationError.invalid }
            var data = try rawData.publicationObject()
            if let title { data["title"] = .string(title) }
            if let body { data["body"] = .string(body) }
            if let folder { data["folder"] = .string(folder) }
            if let profile = data["profile"] {
                guard let bytes = Data(selectiveRemoteBase64URL: try profile.publicationString()), bytes.count <= 384 * 1024 else { throw SelectiveRemoteWholePublicationError.invalid }
                var fields = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: bytes).publicationObject()
                if let title { fields["friendlyName"] = .string(title) }
                if let folder { fields["group"] = .string(folder) }
                data["profile"] = .string(try encoded(.object(fields)).selectiveRemoteBase64URL)
            }
            record["data"] = .object(data); p["record"] = .object(record); changes[id] = p
        }
        switch intent {
        case let .content(title, body):
            guard reference.kind != .folder, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 512, !title.contains(where: \.isNewline),
                  body == nil || (reference.kind == .snippet && body!.utf8.count <= 512 * 1024) else { throw SelectiveRemoteWholePublicationError.invalid }
            try recordChange(source.resourceID, title: title, body: body)
        case let .move(parent):
            let type: String
            if reference.kind == .folder { type = try partPayload(source.resourceID)["folder"]!.publicationObject()["type"]!.publicationString() }
            else { type = reference.kind == .host ? "host" : "snippet" }
            if let parent {
                guard resources.contains(where: { $0["id"] == .string(parent.canonicalCloudString) && $0["kind"] == .string("FOLDER") }),
                      try partPayload(parent)["folder"]!.publicationObject()["type"] == .string(type) else { throw SelectiveRemoteWholePublicationError.scope }
            }
            resources[selected]["parentFolderID"] = parent.map { .string($0.canonicalCloudString) } ?? .null
            func folderPath(_ id: UUID?) throws -> String {
                var current = id, components: [String] = [], visited = Set<UUID>()
                while let id = current {
                    guard visited.insert(id).inserted, visited.count <= 32,
                          let r = resources.first(where: { $0["id"] == .string(id.canonicalCloudString) && $0["kind"] == .string("FOLDER") }) else { throw SelectiveRemoteWholePublicationError.scope }
                    let f = try partPayload(id)["folder"]!.publicationObject(["type", "path", "component"])
                    guard f["type"] == .string(type) else { throw SelectiveRemoteWholePublicationError.scope }
                    let component = try f["component"]!.publicationString()
                    guard try SelectiveRemoteLegacyResourceMapper.folderComponents(component).count == 1 else { throw SelectiveRemoteWholePublicationError.invalid }
                    components.insert(component, at: 0); current = r["parentFolderID"] == .null ? nil : try SelectiveRemoteWholePublicationWire.id(r["parentFolderID"]!)
                }
                return components.joined(separator: "/")
            }
            _ = try folderPath(parent)
            for r in resources {
                let id = try SelectiveRemoteWholePublicationWire.id(r["id"]!)
                var current: UUID? = id, visited = Set<UUID>(), affected = false
                while let c = current {
                    guard visited.insert(c).inserted, visited.count <= 32, let node = resources.first(where: { $0["id"] == .string(c.canonicalCloudString) }) else { throw SelectiveRemoteWholePublicationError.scope }
                    if c == reference.resourceID { affected = true; break }
                    current = node["parentFolderID"] == .null ? nil : try SelectiveRemoteWholePublicationWire.id(node["parentFolderID"]!)
                }
                guard affected else { continue }
                let parentID = r["parentFolderID"] == .null ? nil : try SelectiveRemoteWholePublicationWire.id(r["parentFolderID"]!)
                if r["kind"] == .string("FOLDER") {
                    var p = try partPayload(id), f = try p["folder"]!.publicationObject(); f["path"] = .string(try folderPath(id)); p["folder"] = .object(f); changes[id] = p
                } else {
                    guard r["kind"] == .string(type == "host" ? "HOST" : "SNIPPET") else { throw SelectiveRemoteWholePublicationError.scope }
                    try recordChange(id, folder: folderPath(parentID))
                }
            }
        }
        var changedParts: [String: Data] = [:], content: [SelectiveRemoteJSONValue] = []
        for (id, p) in changes.sorted(by: { $0.key.canonicalCloudString < $1.key.canonicalCloudString }) {
            let bytes = try encoded(.object(p)); guard bytes.count <= 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }
            changedParts[reference.scope.vaultID.canonicalCloudString + "/" + id.canonicalCloudString + "/GENERAL"] = bytes
            content.append(.object(["resourceID": .string(id.canonicalCloudString), "part": .string("GENERAL")]))
        }
        v["resources"] = .array(resources.map(SelectiveRemoteJSONValue.object)); v["contentChanges"] = .array(content)
        return Draft(vault: .object(v), changedParts: changedParts)
    }
    static func grant(vault: SelectiveRemoteJSONValue, reference: SelectiveRemotePublishedModelReference, principal: Principal, mask: Int) throws -> SelectiveRemoteJSONValue {
        let allowed: Int = reference.kind == .credential ? 15 : reference.kind == .folder ? 33 : reference.kind == .forwarding ? 9 : 13
        guard !reference.stale, mask >= 0, mask & ~allowed == 0, mask == 0 || mask & 1 != 0, reference.kind != .credential || mask & 4 == 0 || mask & 2 != 0,
              ["USER", "GROUP"].contains(principal.kind), principal.kind != "USER" || (principal.membershipID != nil && (principal.epoch ?? 0) > 0) else { throw SelectiveRemoteWholePublicationError.invalid }
        var v = try vault.publicationObject(["vaultID", "resources", "policy", "contentChanges", "custodianDeviceIDs"])
        guard v["vaultID"] == .string(reference.scope.vaultID.canonicalCloudString), try v["resources"]!.publicationArray().contains(where: { try $0.publicationObject()["id"] == .string(reference.resourceID.canonicalCloudString) }) else { throw SelectiveRemoteWholePublicationError.scope }
        let targetKind = reference.kind == .folder ? "FOLDER" : "RESOURCE"
        var policies = try v["policy"]!.publicationArray(), existingID: SelectiveRemoteJSONValue?
        policies = try policies.filter { raw in
            let p = try raw.publicationObject()
            let same = p["principalKind"] == .string(principal.kind) && p["principalID"] == .string(principal.id.canonicalCloudString) && p["targetKind"] == .string(targetKind) && p["targetID"] == .string(reference.resourceID.canonicalCloudString)
            if same && (principal.kind == "GROUP" || (p["membershipID"] == .string(principal.membershipID!.canonicalCloudString) && p["membershipEpoch"] == .number(Double(principal.epoch!)))) { existingID = p["id"] }; return !same
        }
        if mask > 0 {
            var grant: [String: SelectiveRemoteJSONValue] = ["id": existingID ?? .string(UUID().canonicalCloudString), "teamID": .string(reference.scope.teamID.canonicalCloudString), "vaultID": v["vaultID"]!, "principalKind": .string(principal.kind), "principalID": .string(principal.id.canonicalCloudString), "targetKind": .string(targetKind), "targetID": .string(reference.resourceID.canonicalCloudString), "mask": .number(Double(mask)), "revokedAt": .null]
            if principal.kind == "USER" { grant["membershipID"] = .string(principal.membershipID!.canonicalCloudString); grant["membershipEpoch"] = .number(Double(principal.epoch!)) }
            policies.append(.object(grant))
        }
        v["policy"] = .array(policies); return .object(v)
    }
}
