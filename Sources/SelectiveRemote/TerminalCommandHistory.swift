import Combine
import Foundation

struct TerminalHistoryContext: Equatable {
    let profileID: UUID
    let snippetTargets: [TerminalSnippetTargetOption]

    init(profileID: UUID, snippetTargets: [TerminalSnippetTargetOption] = []) {
        self.profileID = profileID
        self.snippetTargets = snippetTargets
    }
}

struct TerminalSnippetTargetOption: Encodable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
}

struct TerminalHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let profileID: UUID
    var command: String
    var lastUsedAt: Date
    var useCount: Int
}

struct TerminalCommandFavorite: Codable, Equatable, Identifiable {
    let id: UUID
    let profileID: UUID
    var command: String
    var addedAt: Date
}

struct TerminalCommandTemplate: Codable, Equatable, Identifiable {
    let id: UUID
    let profileID: UUID
    var title: String
    var command: String
    var category: String
    var targetProfileIDs: [UUID]
    var updatedAt: Date

    init(
        id: UUID,
        profileID: UUID,
        title: String,
        command: String,
        category: String,
        targetProfileIDs: [UUID]? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.command = command
        self.category = category
        self.targetProfileIDs = targetProfileIDs ?? [profileID]
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileID, title, command, category, targetProfileIDs, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        title = try container.decode(String.self, forKey: .title)
        command = try container.decode(String.self, forKey: .command)
        category = try container.decode(String.self, forKey: .category)
        targetProfileIDs = try container.decodeIfPresent([UUID].self, forKey: .targetProfileIDs)
            ?? [profileID]
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct TerminalSnippetGroup: Codable, Equatable, Identifiable {
    let id: UUID
    let profileID: UUID
    var name: String
    var createdAt: Date
}

private struct TerminalHistoryWebEntry: Encodable {
    let id: String
    let command: String
    let lastUsedAt: Int64
    let useCount: Int
}

private struct TerminalHistoryWebPayload: Encodable {
    let enabled: Bool
    let entries: [TerminalHistoryWebEntry]
    let favorites: [String]
    let templates: [TerminalCommandTemplateWebEntry]
    let snippetGroups: [TerminalSnippetGroupWebEntry]
    let snippetTargets: [TerminalSnippetTargetOption]
    let defaultSnippetTargetID: String
    let remote: TerminalRemoteContextSnapshot
}

private struct TerminalCommandTemplateWebEntry: Encodable {
    let id: String
    let title: String
    let command: String
    let category: String
    let targetProfileIDs: [String]
    let updatedAt: Int64
}

private struct TerminalSnippetGroupWebEntry: Encodable {
    let id: String
    let name: String
}

@MainActor
final class TerminalCommandHistoryStore: ObservableObject {
    static let shared = TerminalCommandHistoryStore()
    static let defaultSnippetGroupName = "Мои команды"
    static let globalSnippetLibraryID = UUID(
        uuidString: "5A17407D-9F03-4F7B-80FB-BD06D3FA50B1"
    )!

    @Published private(set) var snippetRevision = 0

    private enum Key {
        static let entries = "SelectiveRemote.terminal.commandHistory.v1"
        static let enabled = "SelectiveRemote.terminal.commandHistory.enabled.v1"
        static let favorites = "SelectiveRemote.terminal.commandFavorites.v1"
        static let templates = "SelectiveRemote.terminal.commandTemplates.v1"
        static let snippetGroups = "SelectiveRemote.terminal.snippetGroups.v1"
    }

    private let defaults: UserDefaults
    private let maximumEntries: Int
    private var storedEntries: [TerminalHistoryEntry]
    private var storedFavorites: [TerminalCommandFavorite]
    private var storedTemplates: [TerminalCommandTemplate]
    private var storedSnippetGroups: [TerminalSnippetGroup]

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    init(defaults: UserDefaults = .standard, maximumEntries: Int = 1_000) {
        self.defaults = defaults
        self.maximumEntries = max(1, maximumEntries)
        if defaults.object(forKey: Key.enabled) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Key.enabled)
        }
        if let data = defaults.data(forKey: Key.entries),
           let decoded = try? JSONDecoder().decode([TerminalHistoryEntry].self, from: data) {
            storedEntries = decoded
        } else {
            storedEntries = []
        }
        if let data = defaults.data(forKey: Key.favorites),
           let decoded = try? JSONDecoder().decode([TerminalCommandFavorite].self, from: data) {
            storedFavorites = decoded
        } else {
            storedFavorites = []
        }
        if let data = defaults.data(forKey: Key.templates),
           let decoded = try? JSONDecoder().decode([TerminalCommandTemplate].self, from: data) {
            storedTemplates = decoded
        } else {
            storedTemplates = []
        }
        if let data = defaults.data(forKey: Key.snippetGroups),
           let decoded = try? JSONDecoder().decode([TerminalSnippetGroup].self, from: data) {
            storedSnippetGroups = decoded
        } else {
            storedSnippetGroups = []
        }
        normalizeAndPersistIfNeeded()
        migrateTemplatesToGlobalLibraryIfNeeded()
    }

    @discardableResult
    func record(
        command rawCommand: String,
        profileID: UUID,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled,
              let command = normalizedCommand(rawCommand),
              !isSensitive(command)
        else { return false }

        let previous = storedEntries.first {
            $0.profileID == profileID && $0.command == command
        }
        storedEntries.removeAll {
            $0.profileID == profileID && $0.command == command
        }
        storedEntries.append(
            TerminalHistoryEntry(
                id: previous?.id ?? UUID(),
                profileID: profileID,
                command: command,
                lastUsedAt: now,
                useCount: previous?.useCount == Int.max
                    ? Int.max
                    : (previous?.useCount ?? 0) + 1
            )
        )
        trimAndPersist()
        return true
    }

    func entries(for profileID: UUID) -> [TerminalHistoryEntry] {
        storedEntries
            .filter { $0.profileID == profileID }
            .sorted {
                if $0.lastUsedAt != $1.lastUsedAt {
                    return $0.lastUsedAt > $1.lastUsedAt
                }
                return $0.command.localizedStandardCompare($1.command) == .orderedAscending
            }
    }

    func remove(entryID: UUID, profileID: UUID) {
        let oldCount = storedEntries.count
        storedEntries.removeAll { $0.id == entryID && $0.profileID == profileID }
        if storedEntries.count != oldCount {
            persist()
        }
    }

    func clear(profileID: UUID) {
        let oldCount = storedEntries.count
        storedEntries.removeAll { $0.profileID == profileID }
        if storedEntries.count != oldCount {
            persist()
        }
    }

    func favorites(for profileID: UUID) -> [TerminalCommandFavorite] {
        storedFavorites
            .filter { $0.profileID == profileID }
            .sorted { $0.addedAt > $1.addedAt }
    }

    @discardableResult
    func toggleFavorite(command rawCommand: String, profileID: UUID) -> Bool {
        guard let command = normalizedCommand(rawCommand), !isSensitive(command) else {
            return false
        }
        if let index = storedFavorites.firstIndex(where: {
            $0.profileID == profileID && $0.command == command
        }) {
            storedFavorites.remove(at: index)
            persistFavorites()
            return false
        }
        storedFavorites.append(
            TerminalCommandFavorite(
                id: UUID(),
                profileID: profileID,
                command: command,
                addedAt: Date()
            )
        )
        if storedFavorites.count > 1_000 {
            storedFavorites.sort { $0.addedAt > $1.addedAt }
            storedFavorites = Array(storedFavorites.prefix(1_000))
        }
        persistFavorites()
        return true
    }

    func templates(for profileID: UUID) -> [TerminalCommandTemplate] {
        _ = profileID
        return templates()
    }

    func templates() -> [TerminalCommandTemplate] {
        storedTemplates
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func snippetGroups(for profileID: UUID) -> [TerminalSnippetGroup] {
        _ = profileID
        return snippetGroups()
    }

    func snippetGroups() -> [TerminalSnippetGroup] {
        storedSnippetGroups
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    @discardableResult
    func createSnippetGroup(
        name rawName: String,
        profileID: UUID,
        now: Date = Date()
    ) -> TerminalSnippetGroup? {
        guard let name = normalizedSnippetGroupName(rawName),
              !hasSnippetGroup(named: name)
        else { return nil }

        let group = TerminalSnippetGroup(
            id: UUID(),
            profileID: Self.globalSnippetLibraryID,
            name: name,
            createdAt: now
        )
        storedSnippetGroups.append(group)
        persistSnippetGroups()
        return group
    }

    @discardableResult
    func renameSnippetGroup(
        id: UUID,
        name rawName: String,
        profileID: UUID
    ) -> Bool {
        guard let name = normalizedSnippetGroupName(rawName),
              let index = storedSnippetGroups.firstIndex(where: {
                  $0.id == id
              })
        else { return false }

        let oldName = storedSnippetGroups[index].name
        guard !storedSnippetGroups.contains(where: {
            $0.id != id
                && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
        }) else {
            return false
        }
        storedSnippetGroups[index].name = name
        for templateIndex in storedTemplates.indices where
            storedTemplates[templateIndex].category == oldName {
            storedTemplates[templateIndex].category = name
        }
        persistSnippetGroups()
        persistTemplates()
        return true
    }

    /// Removes a group without deleting its snippets. Snippets are moved to the
    /// existing default group so a category operation cannot destroy commands.
    @discardableResult
    func removeSnippetGroup(id: UUID, profileID: UUID) -> Bool {
        guard let index = storedSnippetGroups.firstIndex(where: {
            $0.id == id
        }) else { return false }

        let removedName = storedSnippetGroups[index].name
        storedSnippetGroups.remove(at: index)
        let affected = storedTemplates.indices.filter {
            storedTemplates[$0].category == removedName
        }
        if !affected.isEmpty {
            let defaultGroup = ensureSnippetGroup(
                named: Self.defaultSnippetGroupName,
                profileID: Self.globalSnippetLibraryID
            )
            for templateIndex in affected {
                storedTemplates[templateIndex].category = defaultGroup.name
                storedTemplates[templateIndex].updatedAt = Date()
            }
            persistTemplates()
        }
        persistSnippetGroups()
        return true
    }

    @discardableResult
    func saveTemplate(
        id: UUID?,
        title rawTitle: String,
        command rawCommand: String,
        category rawCategory: String,
        profileID: UUID,
        targetProfileIDs: [UUID]? = nil
    ) -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.count <= 80,
              category.count <= 60,
              let command = normalizedCommand(rawCommand),
              !isSensitive(command)
        else { return false }

        let group = ensureSnippetGroup(
            named: category.isEmpty ? Self.defaultSnippetGroupName : category,
            profileID: Self.globalSnippetLibraryID
        )

        if let id,
           let index = storedTemplates.firstIndex(where: {
               $0.id == id
           }) {
            storedTemplates[index].title = title
            storedTemplates[index].command = command
            storedTemplates[index].category = group.name
            if let targetProfileIDs {
                storedTemplates[index].targetProfileIDs = normalizedTargetIDs(targetProfileIDs)
            }
            storedTemplates[index].updatedAt = Date()
        } else {
            storedTemplates.append(
                TerminalCommandTemplate(
                    id: UUID(),
                    profileID: profileID,
                    title: title,
                    command: command,
                    category: group.name,
                    targetProfileIDs: normalizedTargetIDs(targetProfileIDs ?? [profileID]),
                    updatedAt: Date()
                )
            )
        }
        persistSnippetGroups()
        if storedTemplates.count > 500 {
            storedTemplates.sort { $0.updatedAt > $1.updatedAt }
            storedTemplates = Array(storedTemplates.prefix(500))
        }
        persistTemplates()
        return true
    }

    @discardableResult
    func moveTemplate(id: UUID, toGroupID groupID: UUID, profileID: UUID) -> Bool {
        guard let group = storedSnippetGroups.first(where: {
            $0.id == groupID
        }), let index = storedTemplates.firstIndex(where: {
            $0.id == id
        }) else { return false }

        storedTemplates[index].category = group.name
        storedTemplates[index].updatedAt = Date()
        persistTemplates()
        return true
    }

    @discardableResult
    func duplicateTemplate(id: UUID, profileID: UUID) -> Bool {
        guard let template = storedTemplates.first(where: {
            $0.id == id
        }) else { return false }

        let suffix = " — копия"
        let base = String(template.title.prefix(max(1, 80 - suffix.count)))

        return saveTemplate(
            id: nil,
            title: base + suffix,
            command: template.command,
            category: template.category,
            profileID: Self.globalSnippetLibraryID,
            targetProfileIDs: template.targetProfileIDs
        )
    }

    func template(id: UUID, profileID: UUID) -> TerminalCommandTemplate? {
        _ = profileID
        return template(id: id)
    }

    func template(id: UUID) -> TerminalCommandTemplate? {
        storedTemplates.first { $0.id == id }
    }

    @discardableResult
    func removeTemplate(id: UUID, profileID: UUID) -> Bool {
        _ = profileID
        return removeTemplate(id: id)
    }

    @discardableResult
    func removeTemplate(id: UUID) -> Bool {
        let oldCount = storedTemplates.count
        storedTemplates.removeAll { $0.id == id }
        if storedTemplates.count != oldCount { persistTemplates() }
        return storedTemplates.count != oldCount
    }

    func webPayload(
        for profileID: UUID,
        snippetTargets: [TerminalSnippetTargetOption] = [],
        remote: TerminalRemoteContextSnapshot = .empty
    ) -> String? {
        let payload = TerminalHistoryWebPayload(
            enabled: isEnabled,
            entries: entries(for: profileID).map {
                TerminalHistoryWebEntry(
                    id: $0.id.uuidString,
                    command: $0.command,
                    lastUsedAt: Int64($0.lastUsedAt.timeIntervalSince1970 * 1_000),
                    useCount: $0.useCount
                )
            },
            favorites: favorites(for: profileID).map(\.command),
            templates: templates().map {
                TerminalCommandTemplateWebEntry(
                    id: $0.id.uuidString,
                    title: $0.title,
                    command: $0.command,
                    category: $0.category,
                    targetProfileIDs: $0.targetProfileIDs.map(\.uuidString),
                    updatedAt: Int64($0.updatedAt.timeIntervalSince1970 * 1_000)
                )
            },
            snippetGroups: snippetGroups().map {
                TerminalSnippetGroupWebEntry(id: $0.id.uuidString, name: $0.name)
            },
            snippetTargets: snippetTargets,
            defaultSnippetTargetID: profileID.uuidString,
            remote: remote
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func normalizedCommand(_ rawCommand: String) -> String? {
        let withoutNewlines = rawCommand.trimmingCharacters(in: .newlines)
        guard !withoutNewlines.isEmpty,
              !withoutNewlines.first!.isWhitespace,
              withoutNewlines.count <= 8_192,
              !withoutNewlines.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && $0.value != 9
              })
        else { return nil }
        return withoutNewlines
    }

    private func isSensitive(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let markers = [
            "authorization:",
            "password=",
            "passwd=",
            "token=",
            "secret=",
            "api_key=",
            "apikey=",
            "private_key="
        ]
        return markers.contains { lowered.contains($0) }
    }

    private func normalizedSnippetGroupName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { return nil }
        return name
    }

    private func hasSnippetGroup(named name: String) -> Bool {
        storedSnippetGroups.contains {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
        }
    }

    @discardableResult
    private func ensureSnippetGroup(
        named rawName: String,
        profileID: UUID,
        now: Date = Date()
    ) -> TerminalSnippetGroup {
        let name = normalizedSnippetGroupName(rawName) ?? Self.defaultSnippetGroupName
        if let existing = storedSnippetGroups.first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
        }) {
            return existing
        }
        let group = TerminalSnippetGroup(
            id: UUID(),
            profileID: Self.globalSnippetLibraryID,
            name: name,
            createdAt: now
        )
        storedSnippetGroups.append(group)
        return group
    }

    private func migrateTemplatesToGlobalLibraryIfNeeded() {
        var templatesChanged = false
        var groupsChanged = false

        var uniqueGroups: [TerminalSnippetGroup] = []
        for group in storedSnippetGroups.sorted(by: { $0.createdAt < $1.createdAt }) {
            if !uniqueGroups.contains(where: {
                $0.name.compare(group.name, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            }) {
                uniqueGroups.append(
                    TerminalSnippetGroup(
                        id: group.id,
                        profileID: Self.globalSnippetLibraryID,
                        name: group.name,
                        createdAt: group.createdAt
                    )
                )
            }
        }
        if uniqueGroups != storedSnippetGroups {
            storedSnippetGroups = uniqueGroups
            groupsChanged = true
        }

        for index in storedTemplates.indices {
            let targets = normalizedTargetIDs(storedTemplates[index].targetProfileIDs)
            if targets != storedTemplates[index].targetProfileIDs {
                storedTemplates[index].targetProfileIDs = targets
                templatesChanged = true
            }
            let trimmed = storedTemplates[index].category
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = trimmed.isEmpty ? Self.defaultSnippetGroupName : trimmed
            if storedTemplates[index].category != resolved {
                storedTemplates[index].category = resolved
                templatesChanged = true
            }
            let beforeCount = storedSnippetGroups.count
            let group = ensureSnippetGroup(
                named: resolved,
                profileID: Self.globalSnippetLibraryID,
                now: storedTemplates[index].updatedAt
            )
            groupsChanged = groupsChanged || storedSnippetGroups.count != beforeCount
            if storedTemplates[index].category != group.name {
                storedTemplates[index].category = group.name
                templatesChanged = true
            }
        }

        if templatesChanged { persistTemplates() }
        if groupsChanged { persistSnippetGroups() }
    }

    private func normalizedTargetIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }

    private func normalizeAndPersistIfNeeded() {
        let normalized = storedEntries
            .filter { normalizedCommand($0.command) != nil }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
        let trimmed = Array(normalized.suffix(maximumEntries))
        if trimmed != storedEntries {
            storedEntries = trimmed
            persist()
        }
    }

    private func trimAndPersist() {
        if storedEntries.count > maximumEntries {
            storedEntries.sort { $0.lastUsedAt < $1.lastUsedAt }
            storedEntries.removeFirst(storedEntries.count - maximumEntries)
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storedEntries) else { return }
        defaults.set(data, forKey: Key.entries)
    }

    private func persistFavorites() {
        guard let data = try? JSONEncoder().encode(storedFavorites) else { return }
        defaults.set(data, forKey: Key.favorites)
    }

    private func persistTemplates() {
        guard let data = try? JSONEncoder().encode(storedTemplates) else { return }
        defaults.set(data, forKey: Key.templates)
        snippetRevision &+= 1
    }

    private func persistSnippetGroups() {
        guard let data = try? JSONEncoder().encode(storedSnippetGroups) else { return }
        defaults.set(data, forKey: Key.snippetGroups)
        snippetRevision &+= 1
    }
}
