import Foundation

// Dormant v2 preparation model. Current v1 Vault documents and path-based UI stay unchanged.
enum VaultResourcePolicyClass: String, Sendable {
    case folder
    case secret
    case general
}

struct VaultResourceIdentity: Equatable, Sendable {
    let id: UUID
    let teamID: UUID
    let vaultID: UUID
    let policyClass: VaultResourcePolicyClass
    let parentFolderID: UUID?
    let schemaVersion = 2
    let resourceVersion: Int

    init(id: UUID = UUID(), teamID: UUID, vaultID: UUID,
         policyClass: VaultResourcePolicyClass, parentFolderID: UUID?, resourceVersion: Int = 1) {
        self.id = id
        self.teamID = teamID
        self.vaultID = vaultID
        self.policyClass = policyClass
        self.parentFolderID = parentFolderID
        self.resourceVersion = resourceVersion
    }

    var canonicalID: String { id.uuidString.lowercased() }
    func renamed() -> Self { self } // Encrypted display name is outside the registry identity.
    func moved(to parentFolderID: UUID?) -> Self {
        Self(id: id, teamID: teamID, vaultID: vaultID, policyClass: policyClass,
             parentFolderID: parentFolderID, resourceVersion: resourceVersion + 1)
    }
    func copied(makeUUID: () -> UUID = UUID.init) -> Self {
        Self(id: makeUUID(), teamID: teamID, vaultID: vaultID, policyClass: policyClass,
             parentFolderID: parentFolderID)
    }
    func duplicated(makeUUID: () -> UUID = UUID.init) -> Self { copied(makeUUID: makeUUID) }
    func imported(makeUUID: () -> UUID = UUID.init) -> Self { copied(makeUUID: makeUUID) }
}

enum VaultFolderNamespace: String, Sendable {
    case host
    case snippet
}

struct VaultFolderIdentity: Equatable, Sendable {
    let id: UUID
    let teamID: UUID
    let vaultID: UUID
    let namespace: VaultFolderNamespace
    let path: String // Kept only in encrypted client migration state, never a registry column.
    let parentFolderID: UUID?
}

enum VaultFolderIdentityError: Error, Equatable {
    case invalidPath
    case invalidName
    case notFound
    case nameConflict
    case invalidParent
    case cycle
    case invalidStagedMap
}

enum VaultFolderIdentityMap {
    static func prepare(teamID: UUID, vaultID: UUID, hostPaths: [String], snippetPaths: [String],
                        existing: [VaultFolderIdentity] = [],
                        makeUUID: () -> UUID = UUID.init) throws -> [VaultFolderIdentity] {
        var result: [VaultFolderIdentity] = existing
        var byPath: [String: VaultFolderIdentity] = [:]
        var seenIDs = Set<UUID>()
        for entry in existing {
            let key = "\(entry.namespace.rawValue):\(entry.path)"
            guard entry.teamID == teamID, entry.vaultID == vaultID,
                  !entry.path.isEmpty, byPath[key] == nil,
                  seenIDs.insert(entry.id).inserted
            else { throw VaultFolderIdentityError.invalidStagedMap }
            byPath[key] = entry
        }
        for (namespace, paths) in [(VaultFolderNamespace.host, hostPaths), (.snippet, snippetPaths)] {
            for fullPath in paths {
                guard !fullPath.isEmpty, !fullPath.hasPrefix("/"), !fullPath.hasSuffix("/"),
                      !fullPath.contains("//") else { throw VaultFolderIdentityError.invalidPath }
                let components = fullPath.split(separator: "/").map(String.init)
                for depth in 1 ... components.count {
                    let path = components.prefix(depth).joined(separator: "/")
                    let key = "\(namespace.rawValue):\(path)"
                    if byPath[key] != nil { continue }
                    let parentPath = components.prefix(depth - 1).joined(separator: "/")
                    let parentID = parentPath.isEmpty ? nil
                        : byPath["\(namespace.rawValue):\(parentPath)"]?.id
                    let entry = VaultFolderIdentity(id: makeUUID(), teamID: teamID, vaultID: vaultID,
                        namespace: namespace, path: path, parentFolderID: parentID)
                    byPath[key] = entry
                    result.append(entry)
                }
            }
        }
        return result
    }

    static func renaming(_ folders: [VaultFolderIdentity], id: UUID,
                         to name: String) throws -> [VaultFolderIdentity] {
        guard !name.isEmpty, !name.contains("/") else { throw VaultFolderIdentityError.invalidName }
        guard let target = folders.first(where: { $0.id == id })
        else { throw VaultFolderIdentityError.notFound }
        let parentPath = target.path.split(separator: "/").dropLast().joined(separator: "/")
        let nextPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        guard !folders.contains(where: { $0.namespace == target.namespace && $0.id != id
            && $0.path == nextPath }) else { throw VaultFolderIdentityError.nameConflict }
        return folders.map { folder in
            guard folder.namespace == target.namespace,
                  folder.path == target.path || folder.path.hasPrefix("\(target.path)/")
            else { return folder }
            let suffix = folder.path.dropFirst(target.path.count)
            return VaultFolderIdentity(id: folder.id, teamID: folder.teamID, vaultID: folder.vaultID,
                namespace: folder.namespace, path: nextPath + suffix,
                parentFolderID: folder.parentFolderID)
        }
    }

    static func moving(_ folders: [VaultFolderIdentity], id: UUID,
                       to newParentID: UUID?) throws -> [VaultFolderIdentity] {
        guard let target = folders.first(where: { $0.id == id })
        else { throw VaultFolderIdentityError.notFound }
        let parent = newParentID.flatMap { candidate in folders.first(where: { $0.id == candidate }) }
        if newParentID != nil && (parent == nil || parent?.teamID != target.teamID
            || parent?.vaultID != target.vaultID || parent?.namespace != target.namespace) {
            throw VaultFolderIdentityError.invalidParent
        }
        if let parent, parent.id == target.id || parent.path.hasPrefix("\(target.path)/") {
            throw VaultFolderIdentityError.cycle
        }
        let name = target.path.split(separator: "/").last.map(String.init) ?? target.path
        let nextPath = parent.map { "\($0.path)/\(name)" } ?? name
        guard !folders.contains(where: { $0.namespace == target.namespace && $0.id != id
            && $0.path == nextPath }) else { throw VaultFolderIdentityError.nameConflict }
        return folders.map { folder in
            guard folder.namespace == target.namespace,
                  folder.path == target.path || folder.path.hasPrefix("\(target.path)/")
            else { return folder }
            let suffix = folder.path.dropFirst(target.path.count)
            return VaultFolderIdentity(id: folder.id, teamID: folder.teamID, vaultID: folder.vaultID,
                namespace: folder.namespace, path: nextPath + suffix,
                parentFolderID: folder.id == id ? newParentID : folder.parentFolderID)
        }
    }
}
