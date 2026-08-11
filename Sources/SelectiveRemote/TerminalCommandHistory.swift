import Foundation

struct TerminalHistoryContext: Equatable {
    let profileID: UUID
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
    var updatedAt: Date
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
    let remote: TerminalRemoteContextSnapshot
}

private struct TerminalCommandTemplateWebEntry: Encodable {
    let id: String
    let title: String
    let command: String
    let category: String
    let updatedAt: Int64
}

@MainActor
final class TerminalCommandHistoryStore {
    static let shared = TerminalCommandHistoryStore()

    private enum Key {
        static let entries = "SelectiveRemote.terminal.commandHistory.v1"
        static let enabled = "SelectiveRemote.terminal.commandHistory.enabled.v1"
        static let favorites = "SelectiveRemote.terminal.commandFavorites.v1"
        static let templates = "SelectiveRemote.terminal.commandTemplates.v1"
    }

    private let defaults: UserDefaults
    private let maximumEntries: Int
    private var storedEntries: [TerminalHistoryEntry]
    private var storedFavorites: [TerminalCommandFavorite]
    private var storedTemplates: [TerminalCommandTemplate]

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
        normalizeAndPersistIfNeeded()
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
        storedTemplates
            .filter { $0.profileID == profileID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func saveTemplate(
        id: UUID?,
        title rawTitle: String,
        command rawCommand: String,
        category rawCategory: String,
        profileID: UUID
    ) -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.count <= 80,
              category.count <= 60,
              let command = normalizedCommand(rawCommand),
              !isSensitive(command)
        else { return false }

        if let id,
           let index = storedTemplates.firstIndex(where: {
               $0.id == id && $0.profileID == profileID
           }) {
            storedTemplates[index].title = title
            storedTemplates[index].command = command
            storedTemplates[index].category = category.isEmpty ? "Мои команды" : category
            storedTemplates[index].updatedAt = Date()
        } else {
            storedTemplates.append(
                TerminalCommandTemplate(
                    id: UUID(),
                    profileID: profileID,
                    title: title,
                    command: command,
                    category: category.isEmpty ? "Мои команды" : category,
                    updatedAt: Date()
                )
            )
        }
        if storedTemplates.count > 500 {
            storedTemplates.sort { $0.updatedAt > $1.updatedAt }
            storedTemplates = Array(storedTemplates.prefix(500))
        }
        persistTemplates()
        return true
    }

    func removeTemplate(id: UUID, profileID: UUID) {
        let oldCount = storedTemplates.count
        storedTemplates.removeAll { $0.id == id && $0.profileID == profileID }
        if storedTemplates.count != oldCount { persistTemplates() }
    }

    func webPayload(
        for profileID: UUID,
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
            templates: templates(for: profileID).map {
                TerminalCommandTemplateWebEntry(
                    id: $0.id.uuidString,
                    title: $0.title,
                    command: $0.command,
                    category: $0.category,
                    updatedAt: Int64($0.updatedAt.timeIntervalSince1970 * 1_000)
                )
            },
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
    }
}
