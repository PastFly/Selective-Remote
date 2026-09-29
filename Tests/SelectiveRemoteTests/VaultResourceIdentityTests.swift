import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Vault v2 identity foundation")
struct VaultResourceIdentityTests {
    private let teamID = UUID(uuidString: "84f6c860-0d26-4ef5-8652-27cb8b991b70")!
    private let vaultID = UUID(uuidString: "bc01823b-1401-4058-9488-f4f6d1839b3b")!

    @Test("copy and import allocate new IDs while rename and move preserve one ID")
    func resourceIdentity() throws {
        let id = UUID(uuidString: "af810efa-fc88-43c4-8557-4105a5ff8140")!
        let next = UUID(uuidString: "c109ab71-06cc-43a1-a37e-bc354ffec608")!
        let source = VaultResourceIdentity(id: id, teamID: teamID, vaultID: vaultID,
                                           policyClass: .general, parentFolderID: nil)
        #expect(source.canonicalID == "af810efa-fc88-43c4-8557-4105a5ff8140")
        #expect(source.renamed().id == id)
        #expect(source.moved(to: nil).id == id)
        #expect(source.copied(makeUUID: { next }).id == next)
        #expect(source.duplicated(makeUUID: { next }).id == next)
        #expect(source.imported(makeUUID: { next }).id == next)
    }

    @Test("Host and Snippet folder preparation keeps distinct nested IDs through rename")
    func folderIdentity() throws {
        let ids = [
            "af810efa-fc88-43c4-8557-4105a5ff8140",
            "c109ab71-06cc-43a1-a37e-bc354ffec608",
            "00e3977b-c4c6-4317-98a9-ef4166c57910",
            "60275e39-febe-4021-b7f9-61173ef56bc0",
            "8b29a8c6-3bf1-493b-9a54-b0a531c455eb"
        ].map { UUID(uuidString: $0)! }
        var position = 0
        let folders = try VaultFolderIdentityMap.prepare(teamID: teamID, vaultID: vaultID,
            hostPaths: ["Ops/Prod", "Sales"], snippetPaths: ["Ops/Prod"], makeUUID: {
                defer { position += 1 }
                return ids[position]
            })
        #expect(folders.count == 5)
        let host = try #require(folders.first { $0.namespace == .host && $0.path == "Ops" })
        let snippet = try #require(folders.first { $0.namespace == .snippet && $0.path == "Ops" })
        #expect(host.id != snippet.id)
        let renamed = try VaultFolderIdentityMap.renaming(folders, id: host.id, to: "Operations")
        #expect(renamed.first { $0.id == host.id }?.path == "Operations")
        #expect(renamed.first { $0.parentFolderID == host.id }?.path == "Operations/Prod")
        #expect(renamed.first { $0.id == snippet.id }?.path == "Ops")
        let sales = try #require(renamed.first { $0.namespace == .host && $0.path == "Sales" })
        let moved = try VaultFolderIdentityMap.moving(renamed, id: host.id, to: sales.id)
        #expect(moved.first { $0.id == host.id }?.id == host.id)
        #expect(moved.first { $0.id == host.id }?.path == "Sales/Operations")
        #expect(moved.first { $0.parentFolderID == host.id }?.path == "Sales/Operations/Prod")
        #expect(throws: VaultFolderIdentityError.invalidParent) {
            try VaultFolderIdentityMap.moving(renamed, id: host.id, to: snippet.id)
        }
        let resumed = try VaultFolderIdentityMap.prepare(teamID: teamID, vaultID: vaultID,
            hostPaths: ["Ops/Prod", "Sales"], snippetPaths: ["Ops/Prod"], existing: folders,
            makeUUID: { Issue.record("unexpected new ID"); return UUID() })
        #expect(resumed == folders)
    }
}
