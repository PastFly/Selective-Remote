import Foundation
import Testing
@testable import SelectiveRemote

struct TeamVaultFilterSharedTests {
    @Test("Hosts and Snippets use one searchable Team Vault selection model")
    func sharedSelection() {
        let teamID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let firstID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let secondID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let hosts = [
            SelectiveRemoteTeamHostVaultContext(
                id: firstID, teamID: teamID, teamName: "Test Team", role: .owner,
                vaultID: firstID, vaultName: "Alpha"
            ),
            SelectiveRemoteTeamHostVaultContext(
                id: secondID, teamID: teamID, teamName: "Test Team", role: .owner,
                vaultID: secondID, vaultName: "Beta"
            )
        ]
        let snippets = hosts.map { vault in
            SelectiveRemoteTeamSnippetVaultContext(
                id: vault.id, teamID: vault.teamID, teamName: vault.teamName,
                role: vault.role, vaultID: vault.vaultID, vaultName: vault.vaultName
            )
        }

        let found = SelectiveRemoteTeamVaultFilterState.search(hosts, query: "bet")
        #expect(found.map(\.vaultID) == [secondID])
        let raw = SelectiveRemoteTeamVaultFilterState.selectAllFiltered(raw: "", vaults: found)
        let hostSelection = SelectiveRemoteTeamVaultFilterState.effectiveKeys(raw: raw, available: hosts)
        let snippetSelection = SelectiveRemoteTeamVaultFilterState.effectiveKeys(raw: raw, available: snippets)
        #expect(hostSelection == snippetSelection)
        #expect(SelectiveRemoteTeamVaultFilterState.includes(
            teamID: teamID, vaultID: secondID, selected: snippetSelection
        ))
        #expect(!SelectiveRemoteTeamVaultFilterState.includes(
            teamID: teamID, vaultID: firstID, selected: snippetSelection
        ))
        #expect(SelectiveRemoteTeamVaultFilterState.decode(
            SelectiveRemoteTeamVaultFilterState.clearAll()
        ).isEmpty)
    }

    @Test("Vault filter preference persists locally and ignores unavailable Vaults")
    func preferenceAndAvailableScope() {
        let teamID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let vaultID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let context = SelectiveRemoteTeamSnippetVaultContext(
            id: vaultID, teamID: teamID, teamName: "Team", role: .viewer,
            vaultID: vaultID, vaultName: "Readable"
        )
        let key = SelectiveRemoteTeamVaultFilterState.key(for: context)
        let suiteName = "SelectiveRemote.TeamVaultFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(SelectiveRemoteTeamVaultFilterState.encode([key]), forKey: "vault-filter")
        let restored = defaults.string(forKey: "vault-filter") ?? ""
        #expect(SelectiveRemoteTeamVaultFilterState.effectiveKeys(
            raw: restored, available: [context]
        ) == [key])
        #expect(SelectiveRemoteTeamVaultFilterState.effectiveKeys(
            raw: restored, available: [SelectiveRemoteTeamSnippetVaultContext]()
        ).isEmpty)
        #expect(!restored.contains("Readable"))
    }

    @Test("Keyboard focus traverses filtered Vaults without losing search")
    func keyboardFocus() {
        let keys = ["one", "two", "three"]
        #expect(SelectiveRemoteTeamVaultFilterState.nextFocus(
            current: nil, keys: keys, direction: .down
        ) == "one")
        #expect(SelectiveRemoteTeamVaultFilterState.nextFocus(
            current: "two", keys: keys, direction: .down
        ) == "three")
        #expect(SelectiveRemoteTeamVaultFilterState.nextFocus(
            current: "one", keys: keys, direction: .up
        ) == nil)
    }

    @Test("Vault search and Select Filtered scale to hundreds without selecting hidden results")
    func largeVaultList() {
        let teamID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let vaults = (0..<150).map { index in
            SelectiveRemoteTeamSnippetVaultContext(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
                teamID: teamID, teamName: "Synthetic Team", role: .viewer,
                vaultID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
                vaultName: String(format: "Vault %03d", index)
            )
        }
        let found = SelectiveRemoteTeamVaultFilterState.search(vaults, query: "Vault 12")
        #expect(found.count == 10)
        let raw = SelectiveRemoteTeamVaultFilterState.selectAllFiltered(raw: "", vaults: found)
        let selected = SelectiveRemoteTeamVaultFilterState.effectiveKeys(raw: raw, available: vaults)
        #expect(selected.count == 10)
        #expect(SelectiveRemoteTeamVaultFilterState.includes(
            teamID: teamID, vaultID: vaults[129].vaultID, selected: selected
        ))
        #expect(!SelectiveRemoteTeamVaultFilterState.includes(
            teamID: teamID, vaultID: vaults[119].vaultID, selected: selected
        ))
    }
}
