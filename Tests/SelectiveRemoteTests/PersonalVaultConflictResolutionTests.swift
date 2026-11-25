import Foundation
import Testing
@testable import SelectiveRemote

struct PersonalVaultConflictResolutionTests {
    private let mac = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let browser = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private let first = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let second = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let unrelated = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
    private let macCredential = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private let cloudCredential = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
    private let time = "2026-11-25T12:00:00.000Z"

    @Test("Mixed choices preserve both originals and keep the Cloud credential identity")
    func mixedChoices() throws {
        let localHost = try record(first, title: "Mac A", device: mac)
        let cloudHost = try record(first, title: "Cloud A", device: browser)
        let native = try credential(macCredential, secret: "synthetic-mac", device: mac)
        let cloud = try credential(cloudCredential, secret: "synthetic-cloud", device: browser)
        let cloudOther = try record(second, title: "Cloud B", device: browser)
        let unrelatedHost = try record(unrelated, title: "Unrelated", device: browser)
        let local = try SelectiveRemoteVaultDocument(records: [
            localHost, native, record(second, title: "Mac B", device: mac)
        ])
        let remote = try SelectiveRemoteVaultDocument(records: [cloudHost, cloud, cloudOther, unrelatedHost])

        let result = try SelectiveRemotePersonalVaultConflictResolution.plan(
            local: local, remote: remote, conflictIDs: [first, second],
            choices: [first: .local, second: .remote], deviceID: mac, resolvedAt: time
        )
        let output = Dictionary(uniqueKeysWithValues: result.document.records.map { ($0.id, $0) })
        #expect(output[first]?.data == localHost.data)
        #expect(output[second] == cloudOther)
        #expect(output[unrelated] == unrelatedHost)
        #expect(output[cloudCredential]?.data == native.data)
        #expect(output[macCredential] == nil)
        #expect(!result.cloudBackup.records.contains(unrelatedHost))
        #expect(result.cloudBackup.records.contains(cloud))
        #expect(result.macBackup.records.contains(native))
    }

    @Test("Taking the Cloud version keeps its deletion and does not require a new Cloud revision")
    func takingCloudDeletion() throws {
        let profile = try record(first, title: "Mac A", device: mac)
        let deleted = try SelectiveRemoteVaultTombstone(
            id: first, version: .init([browser: 2]), deletedAt: time
        )
        let local = try SelectiveRemoteVaultDocument(records: [profile])
        let remote = try SelectiveRemoteVaultDocument(tombstones: [deleted])
        let result = try SelectiveRemotePersonalVaultConflictResolution.plan(
            local: local, remote: remote, conflictIDs: [first],
            choices: [first: .remote], deviceID: mac, resolvedAt: time
        )
        #expect(result.document == remote)
        #expect(result.macBackup == local)
        #expect(result.cloudBackup == remote)
    }

    @Test("Resolution rejects choices made for an incomplete or stale conflict list")
    func rejectsIncompleteChoices() throws {
        let local = try SelectiveRemoteVaultDocument(records: [record(first, title: "Mac", device: mac)])
        let remote = try SelectiveRemoteVaultDocument(records: [record(first, title: "Cloud", device: browser)])
        #expect(throws: SelectiveRemotePersonalVaultConflictResolution.Failure.staleReview) {
            _ = try SelectiveRemotePersonalVaultConflictResolution.plan(
                local: local, remote: remote, conflictIDs: [first],
                choices: [second: .local], deviceID: mac, resolvedAt: time
            )
        }
    }

    @Test("Saved originals are encrypted and retained only once when an attempt is retried")
    func encryptedRecoveryCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try SelectiveRemoteVaultDocument(records: [record(first, title: "TEST-ONLY-MAC", device: mac)])
        let remote = try SelectiveRemoteVaultDocument(records: [record(first, title: "TEST-ONLY-CLOUD", device: browser)])
        let plan = try SelectiveRemotePersonalVaultConflictResolution.plan(
            local: local, remote: remote, conflictIDs: [first],
            choices: [first: .remote], deviceID: mac, resolvedAt: time
        )
        let key = Data(repeating: 7, count: 32)
        let material = try SelectiveRemotePersonalVaultKeyMaterial(
            vaultID: unrelated, vaultKey: key, wrappedKey: .init(
                salt: Data(repeating: 8, count: 16), value: Data(repeating: 9, count: 40)
            ), revision: 2, documentHash: Data(repeating: 10, count: 32), requiresInitialDownload: true
        )
        let firstPath = try SelectiveRemotePersonalVaultConflictCopies.save(plan, material: material, revision: 2, in: root)
        let secondPath = try SelectiveRemotePersonalVaultConflictCopies.save(plan, material: material, revision: 2, in: root)
        #expect(firstPath == secondPath)
        let raw = try Data(contentsOf: firstPath)
        #expect(!String(decoding: raw, as: UTF8.self).contains("TEST-ONLY-"))
        let stored = try JSONDecoder().decode(SelectiveRemotePersonalVaultConflictCopies.self, from: raw)
        #expect(try SelectiveRemotePersonalVaultCrypto.open(stored.mac, vaultKey: key) == local)
        #expect(try SelectiveRemotePersonalVaultCrypto.open(stored.cloud, vaultKey: key) == remote)
    }

    private func record(_ id: UUID, title: String, device: UUID) throws -> SelectiveRemoteVaultRecord {
        try .init(id: id, type: .host, version: .init([device: 1]), modifiedAt: time,
                  data: .object(["title": .string(title), "address": .string("sample.example.invalid")]))
    }

    private func credential(_ id: UUID, secret: String, device: UUID) throws -> SelectiveRemoteVaultRecord {
        try .init(id: id, type: .credential, version: .init([device: 1]), modifiedAt: time,
                  data: .object(["sourceID": .string(first.canonicalCloudString),
                                 "kind": .string("ssh"), "secret": .string(secret)]))
    }
}
