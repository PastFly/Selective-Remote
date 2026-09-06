import CryptoKit
import Foundation

enum SelectiveRemoteTeamVaultSnapshotError: Error, Equatable {
    case invalidSnapshot
    case storageUnavailable
}

struct SelectiveRemoteTeamVaultSnapshot: Codable, Equatable, Sendable {
    let teamID: UUID
    let vaultID: UUID
    let deviceID: UUID
    let keyGeneration: Int
    let localRevision: Int
    let serverRevision: Int
    let syncedLocalRevision: Int
    let envelope: SelectiveRemoteTeamVaultPayloadEnvelope
    let wrapper: SelectiveRemoteTeamVaultKeyWrapper

    enum CodingKeys: String, CodingKey {
        case teamID, vaultID, deviceID, keyGeneration
        case localRevision, serverRevision, syncedLocalRevision
        case envelope, wrapper
    }

    init(
        teamID: UUID,
        vaultID: UUID,
        deviceID: UUID,
        keyGeneration: Int,
        localRevision: Int,
        serverRevision: Int,
        syncedLocalRevision: Int,
        envelope: SelectiveRemoteTeamVaultPayloadEnvelope,
        wrapper: SelectiveRemoteTeamVaultKeyWrapper
    ) throws {
        guard teamID.isSelectiveRemoteCloudUUID,
              vaultID.isSelectiveRemoteCloudUUID,
              deviceID.isSelectiveRemoteCloudUUID,
              keyGeneration > 0,
              localRevision > 0,
              serverRevision >= 0,
              syncedLocalRevision >= 0,
              syncedLocalRevision <= localRevision,
              envelope.keyGeneration == keyGeneration,
              wrapper.deviceID == deviceID
        else { throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot }
        self.teamID = teamID
        self.vaultID = vaultID
        self.deviceID = deviceID
        self.keyGeneration = keyGeneration
        self.localRevision = localRevision
        self.serverRevision = serverRevision
        self.syncedLocalRevision = syncedLocalRevision
        self.envelope = envelope
        self.wrapper = wrapper
    }

    init(from decoder: any Decoder) throws {
        let actualKeys = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self)
            .allKeys.map(\.stringValue).sorted()
        guard actualKeys == [
            "deviceID", "envelope", "keyGeneration", "localRevision", "serverRevision",
            "syncedLocalRevision", "teamID", "vaultID", "wrapper"
        ] else { throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            teamID: values.decode(UUID.self, forKey: .teamID),
            vaultID: values.decode(UUID.self, forKey: .vaultID),
            deviceID: values.decode(UUID.self, forKey: .deviceID),
            keyGeneration: values.decode(Int.self, forKey: .keyGeneration),
            localRevision: values.decode(Int.self, forKey: .localRevision),
            serverRevision: values.decode(Int.self, forKey: .serverRevision),
            syncedLocalRevision: values.decode(Int.self, forKey: .syncedLocalRevision),
            envelope: values.decode(SelectiveRemoteTeamVaultPayloadEnvelope.self, forKey: .envelope),
            wrapper: values.decode(SelectiveRemoteTeamVaultKeyWrapper.self, forKey: .wrapper)
        )
    }
}

protocol SelectiveRemoteTeamVaultSnapshotStore: Sendable {
    func load(endpoint: URL, teamID: UUID, vaultID: UUID) throws -> SelectiveRemoteTeamVaultSnapshot?
    func save(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL) throws
    func remove(endpoint: URL, teamID: UUID, vaultID: UUID) throws
}

struct SelectiveRemoteTeamVaultFileSnapshotStore: SelectiveRemoteTeamVaultSnapshotStore {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable }
            self.root = applicationSupport
                .appending(path: "Selective Remote", directoryHint: .isDirectory)
                .appending(path: "CloudTeamVaults", directoryHint: .isDirectory)
        }
    }

    func load(endpoint: URL, teamID: UUID, vaultID: UUID) throws -> SelectiveRemoteTeamVaultSnapshot? {
        let url = try snapshotURL(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try JSONDecoder().decode(SelectiveRemoteTeamVaultSnapshot.self, from: data)
        } catch let error as SelectiveRemoteTeamVaultSnapshotError {
            throw error
        } catch {
            throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot
        }
    }

    func save(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL) throws {
        let url = try snapshotURL(endpoint: endpoint, teamID: snapshot.teamID, vaultID: snapshot.vaultID)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable
        }
    }

    func remove(endpoint: URL, teamID: UUID, vaultID: UUID) throws {
        let url = try snapshotURL(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable
        }
    }

    private func snapshotURL(endpoint: URL, teamID: UUID, vaultID: UUID) throws -> URL {
        guard teamID.isSelectiveRemoteCloudUUID, vaultID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot
        }
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        let endpointID = Data(SHA256.hash(data: Data(endpoint.absoluteString.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
        return root
            .appending(path: endpointID, directoryHint: .isDirectory)
            .appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
    }
}

final class SelectiveRemoteTeamVaultMemorySnapshotStore: SelectiveRemoteTeamVaultSnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: SelectiveRemoteTeamVaultSnapshot] = [:]

    func load(endpoint: URL, teamID: UUID, vaultID: UUID) throws -> SelectiveRemoteTeamVaultSnapshot? {
        let key = try snapshotKey(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        return lock.withLock { snapshots[key] }
    }

    func save(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL) throws {
        let key = try snapshotKey(endpoint: endpoint, teamID: snapshot.teamID, vaultID: snapshot.vaultID)
        lock.withLock { snapshots[key] = snapshot }
    }

    func remove(endpoint: URL, teamID: UUID, vaultID: UUID) throws {
        let key = try snapshotKey(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        lock.withLock { snapshots.removeValue(forKey: key) }
    }

    private func snapshotKey(endpoint: URL, teamID: UUID, vaultID: UUID) throws -> String {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        guard teamID.isSelectiveRemoteCloudUUID, vaultID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot
        }
        return "\(endpoint.absoluteString)|\(teamID.canonicalCloudString)|\(vaultID.canonicalCloudString)"
    }
}
