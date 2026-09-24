import Foundation

protocol SelectiveRemoteTeamVaultFilterItem: Identifiable {
    var teamID: UUID { get }
    var teamName: String { get }
    var vaultID: UUID { get }
    var vaultName: String { get }
}

extension SelectiveRemoteTeamHostVaultContext: SelectiveRemoteTeamVaultFilterItem {}
extension SelectiveRemoteTeamSnippetVaultContext: SelectiveRemoteTeamVaultFilterItem {}

enum SelectiveRemoteTeamVaultFilterState {
    enum FocusDirection { case up, down }

    static func key(teamID: UUID, vaultID: UUID) -> String {
        "\(teamID.canonicalCloudString)/\(vaultID.canonicalCloudString)"
    }

    static func key<Vault: SelectiveRemoteTeamVaultFilterItem>(for vault: Vault) -> String {
        key(teamID: vault.teamID, vaultID: vault.vaultID)
    }

    static func decode(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(values)
    }

    static func encode(_ keys: Set<String>) -> String {
        guard !keys.isEmpty,
              let data = try? JSONEncoder().encode(keys.sorted()),
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    static func effectiveKeys<Vault: SelectiveRemoteTeamVaultFilterItem>(
        raw: String, available: [Vault]
    ) -> Set<String> {
        decode(raw).intersection(Set(available.map {
            key(teamID: $0.teamID, vaultID: $0.vaultID)
        }))
    }

    static func includes(teamID: UUID, vaultID: UUID, selected: Set<String>) -> Bool {
        selected.isEmpty || selected.contains(key(teamID: teamID, vaultID: vaultID))
    }

    static func search<Vault: SelectiveRemoteTeamVaultFilterItem>(
        _ vaults: [Vault], query: String
    ) -> [Vault] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return vaults.filter {
            term.isEmpty || $0.teamName.localizedCaseInsensitiveContains(term)
                || $0.vaultName.localizedCaseInsensitiveContains(term)
        }.sorted {
            let team = $0.teamName.localizedStandardCompare($1.teamName)
            if team != .orderedSame { return team == .orderedAscending }
            let vault = $0.vaultName.localizedStandardCompare($1.vaultName)
            return vault == .orderedSame
                ? key(for: $0) < key(for: $1)
                : vault == .orderedAscending
        }
    }

    static func selectAllFiltered<Vault: SelectiveRemoteTeamVaultFilterItem>(
        raw: String, vaults: [Vault]
    ) -> String {
        encode(decode(raw).union(vaults.map {
            key(teamID: $0.teamID, vaultID: $0.vaultID)
        }))
    }

    static func clearFiltered<Vault: SelectiveRemoteTeamVaultFilterItem>(
        raw: String, vaults: [Vault]
    ) -> String {
        encode(decode(raw).subtracting(vaults.map {
            key(teamID: $0.teamID, vaultID: $0.vaultID)
        }))
    }

    static func toggle(raw: String, key: String) -> String {
        var selected = decode(raw)
        if !selected.insert(key).inserted { selected.remove(key) }
        return encode(selected)
    }

    static func clearAll() -> String { "" }

    static func nextFocus(
        current: String?, keys: [String], direction: FocusDirection
    ) -> String? {
        guard !keys.isEmpty else { return nil }
        guard let current, let index = keys.firstIndex(of: current) else {
            return direction == .down ? keys.first : keys.last
        }
        switch direction {
        case .down: return keys.indices.contains(index + 1) ? keys[index + 1] : keys.last
        case .up: return index == 0 ? nil : keys[index - 1]
        }
    }
}
