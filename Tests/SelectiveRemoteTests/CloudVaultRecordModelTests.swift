import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Cloud Vault causal record model")
struct CloudVaultRecordModelTests {
    private let deviceA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let deviceB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let deviceC = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let recordA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let recordB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let recordC = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let firstTime = "2026-09-06T00:00:00.000Z"
    private let secondTime = "2026-09-07T00:00:00.000Z"

    @Test("Swift decodes and canonically re-encodes the browser Vault schema")
    func browserSchemaRoundTrip() throws {
        let source = Data(#"""
        {
          "schemaVersion": 1,
          "records": [{
            "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "type": "credential",
            "version": {"22222222-2222-4222-8222-222222222222": 1, "11111111-1111-4111-8111-111111111111": 2},
            "modifiedAt": "2026-09-06T00:00:00.000Z",
            "data": {"username": "operator", "secret": "synthetic", "metadata": [true, null, 3]}
          }],
          "tombstones": []
        }
        """#.utf8)

        let document = try SelectiveRemoteVaultDocument.decode(source)
        #expect(document.records.map(\.id) == [recordA])
        #expect(document.records[0].version.counters == [deviceA: 2, deviceB: 1])
        let encoded = String(decoding: try document.encoded(), as: UTF8.self)
        #expect(encoded.hasPrefix(#"{"records":[{"data":{"metadata":[true,null,3]"#))
        #expect(try SelectiveRemoteVaultDocument.decode(Data(encoded.utf8)) == document)
    }

    @Test("Vault validation rejects unknown structure and unsafe record data")
    func strictValidation() {
        let unknownField = Data(#"""
        {
          "schemaVersion": 1,
          "records": [],
          "tombstones": [],
          "plaintext": "must fail"
        }
        """#.utf8)
        #expect(throws: SelectiveRemoteVaultDocumentError.invalidVaultDocument) {
            try SelectiveRemoteVaultDocument.decode(unknownField)
        }

        let forbiddenData = Data(#"""
        {
          "schemaVersion": 1,
          "records": [{
            "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "type": "host",
            "version": {"11111111-1111-4111-8111-111111111111": 1},
            "modifiedAt": "2026-09-06T00:00:00.000Z",
            "data": {"constructor": "must fail"}
          }],
          "tombstones": []
        }
        """#.utf8)
        #expect(throws: SelectiveRemoteVaultDocumentError.invalidRecordData) {
            try SelectiveRemoteVaultDocument.decode(forbiddenData)
        }
    }

    @Test("Causal dominance merges automatically and concurrency remains explicit")
    func causalMerge() throws {
        let localDominant = try record(
            id: recordA,
            version: [deviceA: 2],
            value: "local-newer",
            modifiedAt: secondTime
        )
        let remoteOlder = try record(
            id: recordA,
            version: [deviceA: 1],
            value: "remote-older",
            modifiedAt: firstTime
        )
        let localConcurrent = try record(
            id: recordB,
            version: [deviceA: 1],
            value: "local-choice",
            modifiedAt: firstTime
        )
        let remoteConcurrent = try record(
            id: recordB,
            version: [deviceB: 1],
            value: "remote-choice",
            modifiedAt: secondTime
        )
        let remoteOnly = try SelectiveRemoteVaultTombstone(
            id: recordC,
            version: .init([deviceB: 1]),
            deletedAt: secondTime
        )

        let local = try SelectiveRemoteVaultDocument(records: [localConcurrent, localDominant])
        let remote = try SelectiveRemoteVaultDocument(
            records: [remoteOlder, remoteConcurrent],
            tombstones: [remoteOnly]
        )
        let merge = try local.merged(with: remote)

        #expect(merge.document.records == [localDominant])
        #expect(merge.document.tombstones == [remoteOnly])
        #expect(merge.conflicts.map(\.id) == [recordB])
        #expect(merge.conflicts[0].local == .record(localConcurrent))
        #expect(merge.conflicts[0].remote == .record(remoteConcurrent))
    }

    @Test("A complete manual choice joins both histories and records the resolver event")
    func completeResolution() throws {
        let local = try record(id: recordB, version: [deviceA: 2], value: "local", modifiedAt: firstTime)
        let remote = try record(id: recordB, version: [deviceB: 1], value: "remote", modifiedAt: secondTime)
        let merge = try SelectiveRemoteVaultDocument(records: [local]).merged(
            with: SelectiveRemoteVaultDocument(records: [remote])
        )

        #expect(throws: SelectiveRemoteVaultDocumentError.incompleteConflictResolutions) {
            try merge.document.resolving(
                merge.conflicts,
                with: [],
                deviceID: deviceC,
                resolvedAt: secondTime
            )
        }
        #expect(throws: SelectiveRemoteVaultDocumentError.duplicateConflictResolution) {
            try merge.document.resolving(
                merge.conflicts,
                with: [
                    .init(id: recordB, choice: .local),
                    .init(id: recordB, choice: .remote)
                ],
                deviceID: deviceC,
                resolvedAt: secondTime
            )
        }
        #expect(throws: SelectiveRemoteVaultDocumentError.unknownConflictResolution) {
            try merge.document.resolving(
                merge.conflicts,
                with: [.init(id: recordC, choice: .local)],
                deviceID: deviceC,
                resolvedAt: secondTime
            )
        }
        let resolved = try merge.document.resolving(
            merge.conflicts,
            with: [.init(id: recordB, choice: .local)],
            deviceID: deviceC,
            resolvedAt: secondTime
        )
        #expect(resolved.records.count == 1)
        #expect(resolved.records[0].data == .object(["value": .string("local")]))
        #expect(resolved.records[0].version.counters == [deviceA: 2, deviceB: 1, deviceC: 1])
        #expect(resolved.records[0].modifiedAt == secondTime)
    }

    @Test("A concurrent edit and deletion remain a conflict and can resolve to a tombstone")
    func editDeletionResolution() throws {
        let edited = try record(
            id: recordA,
            version: [deviceA: 2],
            value: "edited-offline",
            modifiedAt: secondTime
        )
        let deleted = try SelectiveRemoteVaultTombstone(
            id: recordA,
            version: .init([deviceA: 1, deviceB: 1]),
            deletedAt: secondTime
        )
        let merge = try SelectiveRemoteVaultDocument(records: [edited]).merged(
            with: SelectiveRemoteVaultDocument(tombstones: [deleted])
        )

        #expect(merge.conflicts.count == 1)
        #expect(merge.conflicts[0].local == .record(edited))
        #expect(merge.conflicts[0].remote == .tombstone(deleted))
        let resolved = try merge.document.resolving(
            merge.conflicts,
            with: [.init(id: recordA, choice: .remote)],
            deviceID: deviceC,
            resolvedAt: secondTime
        )
        #expect(resolved.records.isEmpty)
        #expect(resolved.tombstones[0].version.counters == [deviceA: 2, deviceB: 1, deviceC: 1])
        #expect(resolved.tombstones[0].deletedAt == secondTime)
    }

    @Test("Automatic policy keeps the newest concurrent value and joins histories")
    func automaticNewestResolution() throws {
        let older = try record(
            id: recordA,
            version: [deviceA: 2],
            value: "older",
            modifiedAt: firstTime
        )
        let newer = try record(
            id: recordA,
            version: [deviceB: 1],
            value: "newer",
            modifiedAt: secondTime
        )
        let result = try SelectiveRemoteVaultDocument(records: [older]).mergedKeepingNewest(
            with: SelectiveRemoteVaultDocument(records: [newer]),
            deviceID: deviceC,
            resolvedAt: secondTime
        )

        #expect(result.resolvedConflictCount == 1)
        #expect(result.document.records[0].data == .object(["value": .string("newer")]))
        #expect(result.document.records[0].version.counters == [deviceA: 2, deviceB: 1, deviceC: 1])
    }

    @Test("Equal-time concurrent deletion wins automatically")
    func automaticDeletionResolution() throws {
        let edited = try record(
            id: recordA,
            version: [deviceA: 2],
            value: "edited",
            modifiedAt: secondTime
        )
        let deleted = try SelectiveRemoteVaultTombstone(
            id: recordA,
            version: .init([deviceA: 1, deviceB: 1]),
            deletedAt: secondTime
        )
        let result = try SelectiveRemoteVaultDocument(records: [edited]).mergedKeepingNewest(
            with: SelectiveRemoteVaultDocument(tombstones: [deleted]),
            deviceID: deviceC,
            resolvedAt: secondTime
        )

        #expect(result.resolvedConflictCount == 1)
        #expect(result.document.records.isEmpty)
        #expect(result.document.tombstones.count == 1)
    }

    private func record(
        id: UUID,
        version: [UUID: Int],
        value: String,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultRecord {
        try .init(
            id: id,
            type: .host,
            version: .init(version),
            modifiedAt: modifiedAt,
            data: .object(["value": .string(value)])
        )
    }
}
