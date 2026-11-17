import CryptoKit
import Darwin
import Foundation

enum SelectiveRemoteTeamVaultSnapshotError: LocalizedError, Equatable {
    case invalidSnapshot
    case storageUnavailable
    case concurrentChange

    var errorDescription: String? {
        switch self {
        case .concurrentChange:
            UpdateLocalization.text(
                ru: "Локальные копии Team Vault изменились одновременно. Синхронизация остановлена; сохраните обе копии и проверьте состояние Vault.",
                en: "Local Team Vault copies changed concurrently. Sync stopped; keep both copies and check the Vault state."
            )
        case .invalidSnapshot:
            UpdateLocalization.text(ru: "Локальная копия Team Vault повреждена или несовместима.", en: "The local Team Vault copy is invalid or incompatible.")
        case .storageUnavailable:
            UpdateLocalization.text(ru: "Локальное хранилище Team Vault недоступно.", en: "Local Team Vault storage is unavailable.")
        }
    }
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
    func saveIfCurrent(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL,
                       replacing expected: SelectiveRemoteTeamVaultSnapshot?) throws
    func remove(endpoint: URL, teamID: UUID, vaultID: UUID) throws
}

extension SelectiveRemoteTeamVaultSnapshotStore {
    // Test adapters may override this. Production stores provide an atomic CAS.
    func saveIfCurrent(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL,
                       replacing expected: SelectiveRemoteTeamVaultSnapshot?) throws {
        guard try load(endpoint: endpoint, teamID: snapshot.teamID, vaultID: snapshot.vaultID) == expected
        else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
        try save(snapshot, endpoint: endpoint)
    }
}

struct SelectiveRemoteTeamVaultFileSnapshotStore: SelectiveRemoteTeamVaultSnapshotStore {
    private static let processLockTable = NSLock()
    nonisolated(unsafe) private static var activePaths: Set<String> = []
    private let root: URL
    private let beforeCommit: @Sendable () throws -> Void

    private struct VersionedSnapshot: Codable {
        let version: Int
        let legacyDigest: String?
        let snapshot: SelectiveRemoteTeamVaultSnapshot?

        enum CodingKeys: String, CodingKey { case version, legacyDigest, snapshot }

        init(legacyDigest: String?, snapshot: SelectiveRemoteTeamVaultSnapshot?) {
            version = 1
            self.legacyDigest = legacyDigest
            self.snapshot = snapshot
        }

        init(from decoder: any Decoder) throws {
            let keys = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self).allKeys.map(\.stringValue).sorted()
            guard keys == ["legacyDigest", "snapshot", "version"] else {
                throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            legacyDigest = try values.decodeIfPresent(String.self, forKey: .legacyDigest)
            snapshot = try values.decodeIfPresent(SelectiveRemoteTeamVaultSnapshot.self, forKey: .snapshot)
            guard version == 1, legacyDigest == nil || (legacyDigest!.count == 64
                && legacyDigest!.allSatisfy({ $0.isHexDigit && !$0.isUppercase })) else {
                throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot
            }
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            if let legacyDigest { try values.encode(legacyDigest, forKey: .legacyDigest) }
            else { try values.encodeNil(forKey: .legacyDigest) }
            if let snapshot { try values.encode(snapshot, forKey: .snapshot) }
            else { try values.encodeNil(forKey: .snapshot) }
        }
    }

    init(root: URL? = nil, beforeCommit: @escaping @Sendable () throws -> Void = {}) throws {
        self.beforeCommit = beforeCommit
        if let root {
            self.root = root
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable }
            self.root = applicationSupport
                .appending(path: "Selective Remote", directoryHint: .isDirectory)
                .appending(path: "CloudTeamVaults", directoryHint: .isDirectory)
        }
    }

    func load(endpoint: URL, teamID: UUID, vaultID: UUID) throws -> SelectiveRemoteTeamVaultSnapshot? {
        let legacyURL = try snapshotURL(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        let state = try readState(legacyURL: legacyURL, teamID: teamID, vaultID: vaultID)
        return state.snapshot
    }

    func save(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL) throws {
        let legacyURL = try snapshotURL(endpoint: endpoint, teamID: snapshot.teamID, vaultID: snapshot.vaultID)
        try withSnapshotLock(versionedURL(legacyURL)) {
            let state = try readState(legacyURL: legacyURL, teamID: snapshot.teamID, vaultID: snapshot.vaultID)
            try commit(snapshot, replacing: state, legacyURL: legacyURL)
        }
    }

    func saveIfCurrent(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL,
                       replacing expected: SelectiveRemoteTeamVaultSnapshot?) throws {
        let legacyURL = try snapshotURL(endpoint: endpoint, teamID: snapshot.teamID, vaultID: snapshot.vaultID)
        try withSnapshotLock(versionedURL(legacyURL)) {
            let state = try readState(legacyURL: legacyURL, teamID: snapshot.teamID, vaultID: snapshot.vaultID)
            guard state.snapshot == expected
            else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
            try commit(snapshot, replacing: state, legacyURL: legacyURL)
        }
    }

    private func commit(_ snapshot: SelectiveRemoteTeamVaultSnapshot?, replacing previous: VersionedSnapshot, legacyURL: URL) throws {
        let currentURL = versionedURL(legacyURL)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Preserve the exact prior version before replacing it. If a legacy
        // writer races this commit, both the previous and attempted states
        // remain available for reconciliation.
        let previousBytes = try readRegularFile(currentURL) ?? encoder.encode(previous)
        try writeBytes(previousBytes, to: currentURL.appendingPathExtension("previous"))
        let pendingURL = currentURL.appendingPathExtension("pending")
        let pending = Darwin.open(pendingURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        if pending < 0 {
            if errno == EEXIST { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
            throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable
        }
        Darwin.close(pending)
        try beforeCommit()
        try write(VersionedSnapshot(legacyDigest: previous.legacyDigest, snapshot: snapshot), to: currentURL)
        // A legacy process cannot honor our lock. It cannot overwrite the new
        // file, and any different retained legacy bytes stop subsequent work.
        guard try digest(readRegularFile(legacyURL)) == previous.legacyDigest
        else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
        do { try FileManager.default.removeItem(at: pendingURL) }
        catch { throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable }
    }

    private func write(_ snapshot: VersionedSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { try writeBytes(encoder.encode(snapshot), to: url) }
        catch { throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable }
    }

    private func writeBytes(_ bytes: Data, to url: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try bytes.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable
        }
    }

    func remove(endpoint: URL, teamID: UUID, vaultID: UUID) throws {
        let legacyURL = try snapshotURL(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        try withSnapshotLock(versionedURL(legacyURL)) {
            let state = try readState(legacyURL: legacyURL, teamID: teamID, vaultID: vaultID)
            // A tombstone prevents the retained legacy file from being
            // silently re-imported on the next load.
            try commit(nil, replacing: state, legacyURL: legacyURL)
        }
    }

    private func readState(legacyURL: URL, teamID: UUID, vaultID: UUID) throws -> VersionedSnapshot {
        let pendingURL = versionedURL(legacyURL).appendingPathExtension("pending")
        guard try readRegularFile(pendingURL) == nil else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
        let legacy = try readRegularFile(legacyURL)
        let legacyDigest = digest(legacy)
        do {
            if let data = try readRegularFile(versionedURL(legacyURL)) {
                let current = try JSONDecoder().decode(VersionedSnapshot.self, from: data)
                guard current.legacyDigest == legacyDigest else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
                guard current.snapshot == nil || (current.snapshot?.teamID == teamID && current.snapshot?.vaultID == vaultID)
                else { throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot }
                guard try readRegularFile(pendingURL) == nil else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
                return current
            }
            if try readRegularFile(versionedURL(legacyURL).appendingPathExtension("previous")) != nil {
                // A missing current file with a retained predecessor is not a
                // first migration; do not resurrect an older legacy copy.
                throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange
            }
            let snapshot = try legacy.map { try JSONDecoder().decode(SelectiveRemoteTeamVaultSnapshot.self, from: $0) }
            guard snapshot == nil || (snapshot?.teamID == teamID && snapshot?.vaultID == vaultID)
            else { throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot }
            guard try readRegularFile(pendingURL) == nil else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
            return VersionedSnapshot(legacyDigest: legacyDigest, snapshot: snapshot)
        } catch let error as SelectiveRemoteTeamVaultSnapshotError {
            throw error
        } catch {
            throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot
        }
    }

    private func readRegularFile(_ url: URL) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot }
        do { return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data() }
        catch { throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable }
    }

    private func digest(_ data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    private func versionedURL(_ legacyURL: URL) -> URL {
        legacyURL.deletingPathExtension().appendingPathExtension("v2.json")
    }

    private func withSnapshotLock<T>(_ url: URL, _ operation: () throws -> T) throws -> T {
        let key = url.standardizedFileURL.path
        let acquired = Self.processLockTable.withLock { Self.activePaths.insert(key).inserted }
        guard acquired else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
        defer { _ = Self.processLockTable.withLock { Self.activePaths.remove(key) } }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable }
        let path = url.appendingPathExtension("lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SelectiveRemoteTeamVaultSnapshotError.storageUnavailable }
        defer { Darwin.close(descriptor) }
        // Never wait while the lifecycle lock is held: another process may
        // be suspended while holding its advisory lock.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
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

    func saveIfCurrent(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL,
                       replacing expected: SelectiveRemoteTeamVaultSnapshot?) throws {
        let key = try snapshotKey(endpoint: endpoint, teamID: snapshot.teamID, vaultID: snapshot.vaultID)
        try lock.withLock {
            guard snapshots[key] == expected else { throw SelectiveRemoteTeamVaultSnapshotError.concurrentChange }
            snapshots[key] = snapshot
        }
    }

    func remove(endpoint: URL, teamID: UUID, vaultID: UUID) throws {
        let key = try snapshotKey(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        _ = lock.withLock { snapshots.removeValue(forKey: key) }
    }

    private func snapshotKey(endpoint: URL, teamID: UUID, vaultID: UUID) throws -> String {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        guard teamID.isSelectiveRemoteCloudUUID, vaultID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot
        }
        return "\(endpoint.absoluteString)|\(teamID.canonicalCloudString)|\(vaultID.canonicalCloudString)"
    }
}
