import AppKit
import SwiftUI

enum TerminalWorkspaceInspectorMode: String, CaseIterable, Identifiable {
    case history = "История"
    case snippets = "Сниппеты"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .history: UpdateLocalization.text(ru: "История", en: "History")
        case .snippets: UpdateLocalization.text(ru: "Сниппеты", en: "Snippets")
        }
    }

    var systemImage: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .snippets: "curlybraces"
        }
    }
}

private enum TerminalWorkspaceInspectorHistorySection: String, CaseIterable, Identifiable {
    case history = "История"
    case catalog = "Общие"
    case server = "Сервер"
    case favorites = "Избранное"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .history: UpdateLocalization.text(ru: "История", en: "History")
        case .catalog: UpdateLocalization.text(ru: "Общие", en: "Common")
        case .server: UpdateLocalization.text(ru: "Сервер", en: "Server")
        case .favorites: UpdateLocalization.text(ru: "Избранное", en: "Favorites")
        }
    }
}

enum TerminalWorkspaceInspectorCopy {
    static var favoriteDescription: String {
        UpdateLocalization.text(ru: "Сохранённая команда", en: "Saved command")
    }

    static func commandSent(to terminalTitle: String) -> String {
        UpdateLocalization.text(
            ru: "Команда отправлена в \(terminalTitle)",
            en: "Command sent to \(terminalTitle)"
        )
    }
}

private enum TerminalWorkspaceInspectorFeedback {
    case connectFirst
    case inserted
    case sent(String)
    case copied
    case snippet(TerminalSnippetRunResult)

    var text: String {
        switch self {
        case .connectFirst:
            UpdateLocalization.text(ru: "Сначала подключите активную SSH-панель", en: "Connect the active SSH pane first")
        case .inserted:
            UpdateLocalization.text(ru: "Команда вставлена — её можно изменить перед запуском", en: "Command inserted — edit it before running")
        case let .sent(title):
            TerminalWorkspaceInspectorCopy.commandSent(to: title)
        case .copied:
            UpdateLocalization.text(ru: "Команда скопирована", en: "Command copied")
        case let .snippet(result):
            switch result {
            case .success: UpdateLocalization.text(ru: "Сниппет отправлен на Targets", en: "Snippet sent to Targets")
            case .connecting: UpdateLocalization.text(ru: "Подключаем Targets — команда выполнится после входа", en: "Connecting Targets — the command will run after sign-in")
            case .noTargets: UpdateLocalization.text(ru: "У сниппета нет доступных Targets", en: "The Snippet has no available Targets")
            case .inactiveSession: UpdateLocalization.text(ru: "SSH-сессия недоступна", en: "The SSH session is unavailable")
            case .invalidSnippet: UpdateLocalization.text(ru: "Сниппет больше недоступен", en: "The Snippet is no longer available")
            }
        }
    }
}

struct TerminalWorkspaceInspector: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: TerminalCommandHistoryStore

    let mode: TerminalWorkspaceInspectorMode
    let profileID: UUID
    let terminalTitle: String
    let sessionIsRunning: Bool
    let remoteContext: TerminalRemoteContextSnapshot
    let selectMode: (TerminalWorkspaceInspectorMode) -> Void
    let refreshRemoteContext: () -> Void
    let close: () -> Void
    let insert: (String) -> Void
    let runHere: (String) -> Void
    let runOnTargets: (TerminalCommandTemplate) -> TerminalSnippetRunResult
    let openSnippetLibrary: () -> Void

    @State private var query = ""
    @State private var feedback: TerminalWorkspaceInspectorFeedback?
    @State private var historySection: TerminalWorkspaceInspectorHistorySection = .history

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

    private var catalogEntries: [TerminalBuiltInCommand] {
        TerminalBuiltInCommandCatalog.entries.filter { entry in
            matchesQuery(entry)
        }
    }

    private var remoteEntries: [TerminalRemoteSuggestion] {
        remoteContext.suggestions.filter {
            normalizedQuery.isEmpty
                || $0.command.localizedLowercase.contains(normalizedQuery)
                || $0.description.localizedLowercase.contains(normalizedQuery)
                || $0.category.localizedLowercase.contains(normalizedQuery)
                || $0.keywords.localizedLowercase.contains(normalizedQuery)
        }
    }

    private var favoriteEntries: [TerminalCommandFavorite] {
        store.favorites(for: profileID).filter {
            normalizedQuery.isEmpty || $0.command.localizedLowercase.contains(normalizedQuery)
        }
    }

    private var inspectorBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var rowBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.045)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            modePicker
            if mode == .history {
                historySectionPicker
            }
            Divider()
            content
            footer
        }
        .frame(minWidth: 330, idealWidth: 390, maxWidth: 440)
        .foregroundStyle(Color.primary)
        .background(inspectorBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                Text(headerTitle).font(.headline)
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
                searchPlaceholder,
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
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var modePicker: some View {
        Picker("Раздел", selection: Binding(
            get: { mode },
            set: { selectMode($0) }
        )) {
            ForEach(TerminalWorkspaceInspectorMode.allCases) { item in
                Label(item.localizedTitle, systemImage: item.systemImage).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var historySectionPicker: some View {
        Picker("Команды", selection: $historySection) {
            ForEach(TerminalWorkspaceInspectorHistorySection.allCases) { section in
                Text(section.localizedTitle).tag(section)
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
        Group {
            switch historySection {
            case .history:
                historyList
            case .catalog:
                commandList(
                    catalogEntries,
                    emptyTitle: UpdateLocalization.text(ru: "Команды не найдены", en: "No commands found"),
                    emptyMessage: UpdateLocalization.text(ru: "Измените запрос или выберите другой раздел.", en: "Change the search or choose another section.")
                )
            case .server:
                remoteCommandList
            case .favorites:
                favoritesList
            }
        }
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                if historyEntries.isEmpty {
                    emptyState(
                        title: UpdateLocalization.text(ru: "История пока пуста", en: "History is empty"),
                        message: UpdateLocalization.text(ru: "Выполненные команды выбранной панели появятся здесь.", en: "Commands run in the selected pane will appear here.")
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
                        UpdateLocalization.dateTimeShort(entry.lastUsedAt)
                            + (entry.useCount > 1
                                ? UpdateLocalization.text(
                                    ru: " · запусков: \(entry.useCount)",
                                    en: " · runs: \(entry.useCount)"
                                )
                                : "")
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.down.to.line.compact")
                    .foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
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

    private func commandList(
        _ entries: [TerminalBuiltInCommand],
        emptyTitle: String,
        emptyMessage: String
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                if entries.isEmpty {
                    emptyState(title: emptyTitle, message: emptyMessage)
                } else {
                    ForEach(entries) { entry in
                        commandRow(
                            command: entry.command,
                            description: entry.description,
                            category: entry.category
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    private var remoteCommandList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                if remoteEntries.isEmpty {
                    emptyState(
                        title: UpdateLocalization.text(ru: "Команды сервера пока недоступны", en: "Server commands are not available yet"),
                        message: remoteContext.message
                    )
                    Button("Обновить контекст сервера", systemImage: "arrow.clockwise") {
                        refreshRemoteContext()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!sessionIsRunning)
                } else {
                    ForEach(remoteEntries) { entry in
                        commandRow(
                            command: entry.command,
                            description: entry.description,
                            category: entry.category
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    private var favoritesList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                if favoriteEntries.isEmpty {
                    emptyState(
                        title: UpdateLocalization.text(ru: "В избранном пока пусто", en: "No favorites yet"),
                        message: UpdateLocalization.text(ru: "Добавьте команду через контекстное меню.", en: "Add a command from the context menu.")
                    )
                } else {
                    ForEach(favoriteEntries) { entry in
                        commandRow(
                            command: entry.command,
                            description: TerminalWorkspaceInspectorCopy.favoriteDescription,
                            category: UpdateLocalization.text(ru: "Избранное", en: "Favorites")
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    private func commandRow(command: String, description: String, category: String) -> some View {
        Button { insertCommand(command) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(category) · \(description)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { runCommand(command) })
        .contextMenu {
            Button("Выполнить здесь", systemImage: "play.fill") { runCommand(command) }
                .disabled(!sessionIsRunning)
            Button("Вставить без запуска", systemImage: "arrow.down.to.line.compact") {
                insertCommand(command)
            }
            .disabled(!sessionIsRunning)
            Button("Скопировать", systemImage: "doc.on.doc") { copy(command) }
            Divider()
            Button(
                store.favorites(for: profileID).contains(where: { $0.command == command })
                    ? "Убрать из избранного"
                    : "В избранное",
                systemImage: "star"
            ) {
                _ = store.toggleFavorite(command: command, profileID: profileID)
            }
        }
    }

    private var snippetsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if snippets.isEmpty {
                    emptyState(
                        title: UpdateLocalization.text(ru: "Сниппеты не найдены", en: "No Snippets found"),
                        message: normalizedQuery.isEmpty
                            ? UpdateLocalization.text(ru: "Создайте команду в общей библиотеке.", en: "Create a command in the shared library.")
                            : UpdateLocalization.text(ru: "Измените поисковый запрос.", en: "Change the search query.")
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
                    Label(
                        "\(snippet.targets.count)",
                        systemImage: snippet.includesLocalTerminal ? "terminal" : "server.rack"
                    )
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
            .background(
                colorScheme == .dark
                    ? Color.accentColor.opacity(0.14)
                    : Color.accentColor.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 10)
            )
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
            if let feedback {
                Text(feedback.text)
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
        .background(rowBackground.opacity(0.65))
    }

    private var headerTitle: String {
        guard mode == .history else { return mode.localizedTitle }
        switch historySection {
        case .history: return UpdateLocalization.text(ru: "История", en: "History")
        case .catalog: return UpdateLocalization.text(ru: "Общие команды", en: "Common Commands")
        case .server: return UpdateLocalization.text(ru: "Команды сервера", en: "Server Commands")
        case .favorites: return UpdateLocalization.text(ru: "Избранное", en: "Favorites")
        }
    }

    private var searchPlaceholder: String {
        mode == .snippets
            ? UpdateLocalization.text(ru: "Поиск сниппетов", en: "Search Snippets")
            : UpdateLocalization.text(ru: "Поиск команд", en: "Search Commands")
    }

    private func matchesQuery(_ entry: TerminalBuiltInCommand) -> Bool {
        normalizedQuery.isEmpty
            || entry.command.localizedLowercase.contains(normalizedQuery)
            || entry.description.localizedLowercase.contains(normalizedQuery)
            || entry.category.localizedLowercase.contains(normalizedQuery)
            || entry.keywords.localizedLowercase.contains(normalizedQuery)
    }

    private func insertCommand(_ command: String) {
        guard sessionIsRunning else {
            feedback = .connectFirst
            return
        }
        insert(command)
        feedback = .inserted
    }

    private func runCommand(_ command: String) {
        guard sessionIsRunning else {
            feedback = .connectFirst
            return
        }
        runHere(command)
        feedback = .sent(terminalTitle)
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        feedback = .copied
    }

    private func report(_ result: TerminalSnippetRunResult) {
        feedback = .snippet(result)
    }
}
