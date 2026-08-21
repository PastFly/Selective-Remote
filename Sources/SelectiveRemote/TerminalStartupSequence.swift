import Foundation
import SwiftUI

private struct TerminalStartupSnippetSequenceRecord: Codable, Equatable, Identifiable {
    let id: String
    var snippetIDs: [UUID]
    let compositeTemplateID: UUID
}

enum TerminalStartupSnippetSequenceError: LocalizedError, Equatable {
    case tooManySnippets
    case missingSnippet
    case invalidCombinedCommand

    var errorDescription: String? {
        switch self {
        case .tooManySnippets:
            "В Startup Sequence можно добавить не больше 8 Snippets."
        case .missingSnippet:
            "Один из выбранных Snippets больше не существует. Обновите последовательность."
        case .invalidCombinedCommand:
            "Общий Startup Sequence слишком длинный или содержит недопустимые данные."
        }
    }
}

@MainActor
final class TerminalStartupSnippetSequenceStore: ObservableObject {
    static let shared = TerminalStartupSnippetSequenceStore()

    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let key = "SelectiveRemote.terminal.startupSnippetSequences.v1"
    private var records: [TerminalStartupSnippetSequenceRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(
               [TerminalStartupSnippetSequenceRecord].self,
               from: data
           ) {
            records = decoded
        } else {
            records = []
        }
    }

    static func profileOwnerKey(_ profileID: UUID) -> String {
        "profile:\(profileID.uuidString.lowercased())"
    }

    static func groupOwnerKey(_ rawGroup: String) -> String {
        let normalized = rawGroup
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return "group:\(normalized)"
    }

    func sequence(
        ownerKey: String,
        legacySnippetID: UUID?,
        library: TerminalCommandHistoryStore
    ) -> [UUID] {
        if let record = records.first(where: { $0.id == ownerKey }) {
            return record.snippetIDs
        }
        guard let legacySnippetID,
              library.template(id: legacySnippetID) != nil,
              !library.isStartupSequenceTemplate(id: legacySnippetID)
        else { return [] }
        return [legacySnippetID]
    }

    /// Persists the visible ordered snippet IDs and returns the ID that the existing
    /// single-startup-snippet runtime should execute. A sequence of two or more
    /// snippets is represented by a hidden multiline template; zero/one snippets
    /// keep the legacy representation for backwards compatibility.
    func apply(
        ownerKey: String,
        snippetIDs rawIDs: [UUID],
        title: String,
        library: TerminalCommandHistoryStore
    ) throws -> UUID? {
        var seen = Set<UUID>()
        let snippetIDs = rawIDs.filter { seen.insert($0).inserted }
        guard snippetIDs.count <= 8 else {
            throw TerminalStartupSnippetSequenceError.tooManySnippets
        }

        if snippetIDs.isEmpty {
            removeRecord(ownerKey: ownerKey, library: library)
            return nil
        }

        guard snippetIDs.allSatisfy({
            library.template(id: $0) != nil && !library.isStartupSequenceTemplate(id: $0)
        }) else {
            throw TerminalStartupSnippetSequenceError.missingSnippet
        }

        if snippetIDs.count == 1 {
            removeRecord(ownerKey: ownerKey, library: library)
            return snippetIDs[0]
        }

        let templates = snippetIDs.compactMap { library.template(id: $0) }
        let combinedCommand = templates.map(\.command).joined(separator: "\n")
        let compositeID = records.first(where: { $0.id == ownerKey })?.compositeTemplateID
            ?? UUID()
        let compositeTitle = String("\(title) · \(templates.count)".prefix(80))
        guard library.upsertStartupSequenceTemplate(
            id: compositeID,
            title: compositeTitle,
            command: combinedCommand
        ) else {
            throw TerminalStartupSnippetSequenceError.invalidCombinedCommand
        }

        if let index = records.firstIndex(where: { $0.id == ownerKey }) {
            records[index].snippetIDs = snippetIDs
        } else {
            records.append(
                TerminalStartupSnippetSequenceRecord(
                    id: ownerKey,
                    snippetIDs: snippetIDs,
                    compositeTemplateID: compositeID
                )
            )
        }
        persist()
        return compositeID
    }

    private func removeRecord(
        ownerKey: String,
        library: TerminalCommandHistoryStore
    ) {
        if let record = records.first(where: { $0.id == ownerKey }) {
            _ = library.removeStartupSequenceTemplate(id: record.compositeTemplateID)
        }
        let previous = records.count
        records.removeAll { $0.id == ownerKey }
        if previous != records.count { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
        revision &+= 1
    }
}

struct TerminalStartupSnippetSequenceEditor: View {
    @ObservedObject private var library = TerminalCommandHistoryStore.shared
    @ObservedObject private var sequenceStore = TerminalStartupSnippetSequenceStore.shared

    let title: String
    let ownerKey: String
    @Binding var startupSnippetID: UUID?
    @Binding var mode: TerminalStartupSnippetMode
    @Binding var afterReconnect: Bool

    @State private var addSnippetID: UUID?
    @State private var feedback: String?

    private var selectedIDs: [UUID] {
        sequenceStore.sequence(
            ownerKey: ownerKey,
            legacySnippetID: startupSnippetID,
            library: library
        )
    }

    private var availableSnippets: [TerminalCommandTemplate] {
        let selected = Set(selectedIDs)
        return library.templates().filter { !selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: "list.number")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(selectedIDs.count)/8")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if selectedIDs.isEmpty {
                Text("Последовательность пока пуста. Добавьте один или несколько Snippets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(selectedIDs.enumerated()), id: \.element) { index, snippetID in
                        sequenceRow(snippetID: snippetID, index: index)
                    }
                }
            }

            HStack(spacing: 8) {
                Picker("Добавить Snippet", selection: $addSnippetID) {
                    Text("Выберите Snippet…").tag(UUID?.none)
                    ForEach(availableSnippets) { snippet in
                        Text(snippet.title).tag(Optional(snippet.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)

                Button("Добавить", systemImage: "plus") {
                    guard let addSnippetID else { return }
                    apply(selectedIDs + [addSnippetID])
                    self.addSnippetID = nil
                }
                .buttonStyle(.bordered)
                .disabled(addSnippetID == nil || selectedIDs.count >= 8)
            }

            HStack(spacing: 12) {
                Picker("Запуск", selection: $mode) {
                    ForEach(TerminalStartupSnippetMode.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .frame(width: 220)

                Toggle("После reconnect", isOn: $afterReconnect)
                    .disabled(mode == .disabled || selectedIDs.isEmpty)
            }

            Text(
                "Snippets выполняются сверху вниз после появления shell prompt. "
                    + "Режим «Спрашивать» подтверждает всю последовательность перед отправкой."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let feedback {
                Label(feedback, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sequenceRow(snippetID: UUID, index: Int) -> some View {
        let snippet = library.template(id: snippetID)
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet?.title ?? "Удалённый Snippet")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let command = snippet?.command {
                    Text(command.replacingOccurrences(of: "\n", with: " ↵ "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                move(index, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Выше")
            Button {
                move(index, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index >= selectedIDs.count - 1)
            .help("Ниже")
            Button(role: .destructive) {
                var ids = selectedIDs
                ids.remove(at: index)
                apply(ids)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Убрать из Startup Sequence")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        var ids = selectedIDs
        guard ids.indices.contains(index), ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        apply(ids)
    }

    private func apply(_ ids: [UUID]) {
        do {
            startupSnippetID = try sequenceStore.apply(
                ownerKey: ownerKey,
                snippetIDs: ids,
                title: title,
                library: library
            )
            feedback = nil
            if ids.isEmpty { mode = .disabled }
        } catch {
            feedback = error.localizedDescription
        }
    }
}
