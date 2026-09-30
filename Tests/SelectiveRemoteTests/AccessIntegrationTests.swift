import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Access integration")
@MainActor
struct AccessIntegrationTests {
    private let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let vault = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let resource = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    @Test("Only committed current-account effective changes become opaque notifications")
    func committedCandidates() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let center = MacNotificationCenter(defaults: defaults, installationID: UUID())
        center.setAccount(user)
        let candidates = [
            CloudAccessNotificationCandidate(userID: other, vaultID: nil, resourceID: resource, gainedMask: 1, lostMask: 0),
            CloudAccessNotificationCandidate(userID: user, vaultID: nil, resourceID: resource, gainedMask: 0, lostMask: 0),
            CloudAccessNotificationCandidate(userID: user, vaultID: nil, resourceID: resource, gainedMask: 1, lostMask: 0),
            CloudAccessNotificationCandidate(userID: user, vaultID: nil, resourceID: resource, gainedMask: 1, lostMask: 0)
        ]
        center.observeCommittedAccess(candidates, referenceVaultID: vault)
        #expect(center.items.count == 1)
        #expect(center.items[0].sourceID.lowercased() == resource.uuidString.lowercased())
        #expect(center.items[0].kind == .accessGained)
        let otherVault = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        center.observeCommittedAccess([
            .init(userID: user, vaultID: otherVault, resourceID: resource,
                  gainedMask: 0, lostMask: 4)
        ], referenceVaultID: vault)
        #expect(center.items.count == 2)
        #expect(center.items.contains { $0.group == .access(otherVault) && $0.kind == .accessLost })
        center.setAccount(other)
        #expect(center.items.isEmpty)
    }

    @Test("A second Personal copy receives a fresh Host and linked Credential identity")
    func freshCopyIdentity() throws {
        let original = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.id = original
        profile.host = "example.invalid"
        let credential = SelectiveRemotePersonalVaultCredentialInput(
            sourceID: original, kind: .ssh, title: "SSH", username: "user", secret: "test-secret"
        )
        let first = SelectiveRemotePersonalTeamCopyIdentity.make(sourceID: original)
        let second = SelectiveRemotePersonalTeamCopyIdentity.make(sourceID: original)
        let (firstProfile, firstCredentials) = first.remap(profile, credentials: [credential])
        let (secondProfile, secondCredentials) = second.remap(profile, credentials: [credential])
        let device = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let firstRecords = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [firstProfile], credentials: firstCredentials,
            snippets: [], forwarding: [], deviceID: device
        ).document.records
        let secondRecords = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [secondProfile], credentials: secondCredentials,
            snippets: [], forwarding: [], deviceID: device
        ).document.records
        #expect(first.hostID != original)
        #expect(second.hostID != first.hostID)
        #expect(first.credentialID(kind: .ssh) != second.credentialID(kind: .ssh))
        #expect(Set(firstRecords.map(\.id)).isDisjoint(with: Set(secondRecords.map(\.id))))
        #expect(firstCredentials[0].sourceID == first.hostID)
        #expect(secondCredentials[0].sourceID == second.hostID)
        #expect(profile.id == original)
        #expect(credential.sourceID == original)
    }

    @Test("One move decision preserves V1/reorder and blocks unmapped V2 ancestry")
    func moveGate() {
        #expect(AccessMoveDecision.decide(formatState: .v1Active, changesAncestry: true).explanation == nil)
        #expect(AccessMoveDecision.decide(formatState: .preparing, changesAncestry: false).explanation == nil)
        #expect(AccessMoveDecision.decide(formatState: .preparing, changesAncestry: true).explanation != nil)
        #expect(AccessMoveDecision.decide(formatState: .active, changesAncestry: true).explanation != nil)
    }
}
