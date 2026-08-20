import AppKit
import SwiftUI

enum TerminalWorkspaceInspectorMode: String, CaseIterable, Identifiable {
    case history = "История"
    case snippets = "Сниппеты"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .snippets: "text.badge.plus"
        }
    }
}

struct TerminalWorkspaceInspector: View {
    @ObservedObject var store: TerminalCommandHistoryStore

    let mode: TerminalWorkspaceInspectorMode
    let profileID: UUID
    let terminalTitle: String
    let sessionIsRunning: Bool
    let selectMode: (TerminalWorkspaceInspectorMode) -> Void
    let close: () -> Void
    let insert: (String) -> Void
    let runHere: (String) -> Void
    let runOnTargets: (TerminalCommandTemplate) -> TerminalSnippetRunResult
    let openSnippetLibrary: () -> Void

    @State private var query = ""
    @State private var feedback = ""

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    private var historyEntries: [TerminalHistoryEntry] {
        store.entries(for: profileID).filter {
            normalizedQuery.isEmpty || $0.command.localizedLowercase.contains(normalizedQuery)
        }
    }

    private var snippets: [TerminalCommandTemplate] {
        store.templates().filter {
            normalizedQuery.isEmpty
                || $0.title.localizedLowercase.contains(normalizedQuery)
                || $0.command.localizedLowercase.contains(normalizedQuery)
                || $0.category.localizedLowercase.contains(normalizedQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            modePicker
            Divider()
            content
            footer
        }
        .frame(minWidth: 330, idealWidth: 390, maxWidth: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .shadow(color: Color.black.opacity(0.22), radius: 22, x: -8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Инспектор терминала")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: mode.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.rawValue).font(.headline)
                Text(terminalTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .help("Закрыть инспектор")
        }
        .padding(14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                mode == .history ? "Поиск команд" : "Поиск сниппетов",
                text: $query
            )
            .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var modePicker: some View {
        Picker("Раздел", selection: Binding(
            get: { mode },
            set: { selectMode($0) }
        )) {
            ForEach(TerminalWorkspaceInspectorMode.allCases) { item in
                Label(item.rawValue, systemImage: item.systemImage).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .history:
            historyContent
        case .snippets:
            snippetsContent
        }
    }

    private var historyContent: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                if historyEntries.isEmpty {
                    emptyState(
                        title: "История пока пуста",
                        message: "Выполненные команды выбранной панели появятся здесь."
                    )
                } else {
                    ForEach(historyEntries) { entry in
                        historyRow(entry)
                    }
                }
            }
            .padding(12)
        }
    }

    private func historyRow(_ entry: TerminalHistoryEntry) -> some View {
        Button {
            insertCommand(entry.command)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(
                        "\(entry.lastUsedAt.formatted(date: .abbreviated, time: .shortened))"
                            + (entry.useCount > 1 ? " · запусков: \(entry.useCount)" : "")
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.down.to.line.compact")
                    .foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { runCommand(entry.command) })
        .contextMenu {
            Button("Выполнить здесь", systemImage: "play.fill") { runCommand(entry.command) }
                .disabled(!sessionIsRunning)
            Button("Вставить без запуска", systemImage: "arrow.down.to.line.compact") {
                insertCommand(entry.command)
            }
            .disabled(!sessionIsRunning)
            Button("Скопировать", systemImage: "doc.on.doc") { copy(entry.command) }
            Divider()
            Button(
                store.favorites(for: profileID).contains(where: { $0.command == entry.command })
                    ? "Убрать из избранного"
                    : "В избранное",
                systemImage: "star"
            ) {
                _ = store.toggleFavorite(command: entry.command, profileID: profileID)
            }
            Button("Удалить из истории", systemImage: "trash", role: .destructive) {
                store.remove(entryID: entry.id, profileID: profileID)
            }
        }
    }

    private var snippetsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if snippets.isEmpty {
                    emptyState(
                        title: "Сниппеты не найдены",
                        message: normalizedQuery.isEmpty
                            ? "Создайте команду в общей библиотеке."
                            : "Измените поисковый запрос."
                    )
                } else {
                    ForEach(store.snippetGroups()) { group in
                        let groupSnippets = snippets.filter { $0.groupID == group.id }
                        if !groupSnippets.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Label(group.name, systemImage: "folder.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(groupSnippets.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                ForEach(groupSnippets) { snippet in
                                    snippetRow(snippet)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func snippetRow(_ snippet: TerminalCommandTemplate) -> some View {
        Button {
            insertCommand(snippet.command)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(snippet.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Label("\(snippet.targetProfileIDs.count)", systemImage: "server.rack")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(snippet.command.replacingOccurrences(of: "\n", with: " ↵ "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { runCommand(snippet.command) })
        .contextMenu {
            Button("Выполнить здесь", systemImage: "play.fill") { runCommand(snippet.command) }
                .disabled(!sessionIsRunning)
            Button("Выполнить на Targets", systemImage: "paperplane.fill") {
                report(runOnTargets(snippet))
            }
            Button("Вставить без запуска", systemImage: "arrow.down.to.line.compact") {
                insertCommand(snippet.command)
            }
            .disabled(!sessionIsRunning)
            Button("Скопировать", systemImage: "doc.on.doc") { copy(snippet.command) }
        }
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var footer: some View {
        VStack(spacing: 7) {
            if !feedback.isEmpty {
                Text(feedback)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
            }
            if mode == .snippets {
                Button("Управлять библиотекой", systemImage: "curlybraces") {
                    openSnippetLibrary()
                }
                .buttonStyle(.bordered)
            }
            Text("Один клик вставляет · двойной выполняет в активной панели")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.primary.opacity(0.025))
    }

    private func insertCommand(_ command: String) {
        guard sessionIsRunning else {
            feedback = "Сначала подключите активную SSH-панель"
            return
        }
        insert(command)
        feedback = "Команда вставлена — её можно изменить перед запуском"
    }

    private func runCommand(_ command: String) {
        guard sessionIsRunning else {
            feedback = "Сначала подключите активную SSH-панель"
            return
        }
        runHere(command)
        feedback = "Команда отправлена в \(terminalTitle)"
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        feedback = "Команда скопирована"
    }

    private func report(_ result: TerminalSnippetRunResult) {
        feedback = switch result {
        case .success: "Сниппет отправлен на Targets"
        case .connecting: "Подключаем Targets — команда выполнится после входа"
        case .noTargets: "У сниппета нет доступных Targets"
        case .inactiveSession: "SSH-сессия недоступна"
        case .invalidSnippet: "Сниппет больше недоступен"
        }
    }
}
