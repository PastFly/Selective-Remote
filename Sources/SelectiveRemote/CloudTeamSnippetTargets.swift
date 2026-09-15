import Combine
import Foundation

/// Persists only the user's local mapping between opaque Team Snippet IDs and
/// Personal SSH profile IDs. Decrypted Team Vault content never enters this store.
@MainActor
final class SelectiveRemoteTeamSnippetTargetStore: ObservableObject {
    static let shared = SelectiveRemoteTeamSnippetTargetStore()

    @Published private var assignments: [String: [String]]
    private let defaults: UserDefaults
    private let defaultsKey: String

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "SelectiveRemote.teamSnippetTargets.v1"
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        assignments = Self.load(defaults: defaults, key: defaultsKey)
    }

    func targets(for snippetID: UUID) -> [UUID] {
        (assignments[snippetID.uuidString] ?? []).compactMap(UUID.init(uuidString:))
    }

    func setTargets(_ profileIDs: [UUID], for snippetID: UUID) {
        let normalized = Array(Set(profileIDs)).sorted { $0.uuidString < $1.uuidString }
        if normalized.isEmpty {
            assignments.removeValue(forKey: snippetID.uuidString)
        } else {
            assignments[snippetID.uuidString] = normalized.map(\.uuidString)
        }
        persist()
    }

    private static func load(defaults: UserDefaults, key: String) -> [String: [String]] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
