import Foundation
import Testing
@testable import SelectiveRemote

@Suite("exact legacy resource identity")
struct CloudLegacyResourceMappingTests {
    let team = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let vault = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let first = "33333333-3333-4333-8333-333333333333"
    let second = "44444444-4444-4444-8444-444444444444"
    func document(_ rows: [(String, String, String)]) -> SelectiveRemoteJSONValue {
        .object(["schemaVersion": .number(1), "tombstones": .array([]), "vectorClock": .object([:]),
            "records": .array(rows.map { id, type, folder in .object(["id": .string(id), "type": .string(type),
                "version": .object([first: .number(2)]), "modifiedAt": .string("2026-10-01T00:00:00Z"),
                "data": .object(["folder": .string(folder), "title": .string("Title")])]) })])
    }
    @Test("byte-distinct Unicode folder names cannot collapse through Swift String equality")
    func unicode() throws {
        let d = document([(first, "host", "A/é"), (second, "host", "A/e\u{301}")])
        let a = try SelectiveRemoteLegacyResourceMapper.map(d, teamID: team, vaultID: vault)
        #expect(a.resources.filter { $0.kind == "FOLDER" }.count == 3)
        #expect(a.mapping["folder:host:QS_DqQ"] != a.mapping["folder:host:QS9lzIE"])
        let b = try SelectiveRemoteLegacyResourceMapper.map(document([(second, "host", "A/e\u{301}"), (first, "host", "A/é")]),
            teamID: team, vaultID: vault, previous: a)
        #expect(a.mapping == b.mapping)
        #expect(a.resources[0].id == first)
    }
    @Test("duplicate live IDs, tombstones and invalid paths reject complete conversion")
    func blockers() throws {
        #expect(throws: SelectiveRemoteLegacyMappingError.duplicateSourceID) {
            try SelectiveRemoteLegacyResourceMapper.map(document([(first, "host", "A"), (first, "snippet", "B")]), teamID: team, vaultID: vault)
        }
        for path in ["A//B", "A/../B", "A/./B", "A/\u{0}B"] {
            #expect(throws: SelectiveRemoteLegacyMappingError.invalidFolder) {
                try SelectiveRemoteLegacyResourceMapper.map(document([(first, "host", path)]), teamID: team, vaultID: vault)
            }
        }
        var d = try document([(first, "host", "A")]).publicationObject()
        d["tombstones"] = .array([.object(["id": .string(first), "deletedAt": .string("2026-10-01T00:00:00Z")])])
        #expect(throws: SelectiveRemoteLegacyMappingError.tombstonedSourceID) {
            try SelectiveRemoteLegacyResourceMapper.map(.object(d), teamID: team, vaultID: vault)
        }
    }
    @Test("persisted invalid source mapping stays stable and cannot cross account scope")
    func generated() throws {
        let d = document([("old-id", "host", "A")])
        let firstMap = try SelectiveRemoteLegacyResourceMapper.map(d, teamID: team, vaultID: vault)
        #expect(try SelectiveRemoteLegacyResourceMapper.map(d, teamID: team, vaultID: vault, previous: firstMap).mapping == firstMap.mapping)
        #expect(throws: SelectiveRemoteLegacyMappingError.collision) {
            try SelectiveRemoteLegacyResourceMapper.map(d, teamID: team, vaultID: vault, previous: firstMap,
                reservedIDs: [firstMap.resources[0].id])
        }
        #expect(throws: SelectiveRemoteLegacyMappingError.scope) {
            try SelectiveRemoteLegacyResourceMapper.map(d, teamID: UUID(), vaultID: vault, previous: firstMap)
        }
    }
}
