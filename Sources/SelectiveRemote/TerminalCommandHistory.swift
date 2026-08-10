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

private struct TerminalHistoryWebEntry: Encodable {
    let id: String
    let command: String
    let lastUsedAt: Int64
    let useCount: Int
}

private struct TerminalHistoryWebPayload: Encodable {
    let enabled: Bool
    let entries: [TerminalHistoryWebEntry]
}

@MainActor
final class TerminalCommandHistoryStore {
    static let shared = TerminalCommandHistoryStore()

    private enum Key {
        static let entries = "SelectiveRemote.terminal.commandHistory.v1"
        static let enabled = "SelectiveRemote.terminal.commandHistory.enabled.v1"
    }

    private let defaults: UserDefaults
    private let maximumEntries: Int
    private var storedEntries: [TerminalHistoryEntry]

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

    func webPayload(for profileID: UUID) -> String? {
        let payload = TerminalHistoryWebPayload(
            enabled: isEnabled,
            entries: entries(for: profileID).map {
                TerminalHistoryWebEntry(
                    id: $0.id.uuidString,
                    command: $0.command,
                    lastUsedAt: Int64($0.lastUsedAt.timeIntervalSince1970 * 1_000),
                    useCount: $0.useCount
                )
            }
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
}
