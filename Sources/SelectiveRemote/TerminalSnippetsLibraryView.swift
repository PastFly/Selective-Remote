import AppKit
import SwiftUI

private enum SnippetLibraryViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
    var systemImage: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

private enum SnippetLibrarySort: String, CaseIterable, Identifiable {
    case name, modified
    var id: String { rawValue }
    var title: String { self == .name ? "Имя" : "Последнее изменение" }
}

struct TerminalSnippetsLibraryView: View {
    @ObservedObject var store: TerminalCommandHistoryStore
    @ObservedObject var model: AppModel

    @State private var query = ""
    @State private var selectedSnippetID: UUID?
    @State private var selectedGroupID: UUID?
    @State private var editorRequest: TerminalSnippetEditorRequest?
    @State private var groupEditor: TerminalSnippetGroup?
    @State private var groupEditorPresented = false
    @State private var deleteSnippet: TerminalCommandTemplate?
    @State private var showsDisconnectConfirmation = false
    @AppStorage("SelectiveRemote.snippets.libraryViewMode.v1")
    private var viewModeRaw = SnippetLibraryViewMode.list.rawValue
    @AppStorage("SelectiveRemote.snippets.selectedGroupID.v1")
    private var persistedGroupID = ""
    @AppStorage("SelectiveRemote.snippets.selectedSnippetID.v1")
    private var persistedSnippetID = ""
    @AppStorage("SelectiveRemote.snippets.sort.v1") private var sortRaw = SnippetLibrarySort.name.rawValue
    @AppStorage("SelectiveRemote.snippets.sortAscending.v1") private var sortAscending = true

    private var viewMode: SnippetLibraryViewMode {
        get { SnippetLibraryViewMode(rawValue: viewModeRaw) ?? .list }
        nonmutating set { viewModeRaw = newValue.rawValue }
    }

    private var selectedSnippet: TerminalCommandTemplate? {
        guard let selectedSnippetID else { return nil }
        return store.template(id: selectedSnippetID)
    }

    private var selectedGroup: TerminalSnippetGroup? {
        guard let selectedGroupID else { return nil }
        return store.snippetGroup(id: selectedGroupID)
    }

    private var sortedProfiles: [ConnectionProfile] {
        model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName)
                    == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let summary = model.latestSnippetRun {
                runStatus(summary)
            }
            Divider()
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    libraryBrowser
                        .frame(width: max(430, proxy.size.width * 0.56))
                    Divider()
                    inspector
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(item: $editorRequest) { request in
            TerminalSnippetEditorView(
                snippet: request.snippet,
                preferredGroupID: request.preferredGroupID,
                groups: store.snippetGroups(),
                profiles: sortedProfiles
            ) { draft in
                let profileID = draft.firstSSHProfileID
                    ?? TerminalCommandHistoryStore.globalSnippetLibraryID
                let saved = store.saveTemplate(
                    id: draft.id,
                    title: draft.title,
                    command: draft.command,
                    category: draft.category,
                    groupID: draft.groupID,
                    profileID: profileID,
                    targets: draft.targets
                )
                if saved {
                    let resolved = draft.id ?? store.templates().first?.id
                    selectSnippet(resolved)
                }
                return saved
            }
        }
        .sheet(isPresented: $groupEditorPresented) {
            TerminalSnippetGroupEditorView(group: groupEditor) { name in
                if let groupEditor {
                    _ = store.renameSnippetGroup(
                        id: groupEditor.id,
                        name: name,
                        profileID: TerminalCommandHistoryStore.globalSnippetLibraryID
                    )
                } else {
                    _ = store.createSnippetGroup(
                        name: name,
                        profileID: TerminalCommandHistoryStore.globalSnippetLibraryID
                    )
                }
            }
        }
        .alert(
            "Удалить сниппет?",
            isPresented: Binding(
                get: { deleteSnippet != nil },
                set: { if !$0 { deleteSnippet = nil } }
            ),
            presenting: deleteSnippet
        ) { snippet in
            Button("Удалить", role: .destructive) {
                if store.removeTemplate(id: snippet.id), selectedSnippetID == snippet.id {
                    selectSnippet(nil)
                }
                deleteSnippet = nil
            }
            Button("Отмена", role: .cancel) { deleteSnippet = nil }
        } message: { snippet in
            Text("«\(snippet.title)» будет удалён из общей библиотеки Snippets.")
        }
        .alert("Отключить SSH Targets?", isPresented: $showsDisconnectConfirmation) {
            Button("Отключить", role: .destructive) {
                model.disconnectTerminalSnippetTargets(
                    model.latestSnippetRun?.targets.map(\.profileID) ?? []
                )
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Активные SSH-сессии Targets последнего запуска будут завершены. Выполняющаяся команда может быть прервана.")
        }
        .onAppear {
            restoreNavigation()
        }
        .onChange(of: store.snippetRevision) { _, _ in
            if let selectedSnippetID, store.template(id: selectedSnippetID) == nil {
                selectSnippet(nil)
            }
            if let selectedGroupID, store.snippetGroup(id: selectedGroupID) == nil {
                openRoot()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Сниппеты")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Общая библиотека команд · SSH и Локальный терминал используют одни Snippets")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                groupEditor = nil
                groupEditorPresented = true
            } label: {
                Label("Новая группа", systemImage: "folder.badge.plus")
            }
            Button {
                presentEditor(nil, preferredGroupID: selectedGroupID)
            } label: {
                Label("Новый сниппет", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private var libraryBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if selectedGroup != nil {
                    Button {
                        openRoot()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Вернуться ко всем группам")
                }
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск сниппетов", text: $query)
                    .textFieldStyle(.plain)
                Spacer(minLength: 6)
                Picker("Вид", selection: Binding(
                    get: { viewMode },
                    set: { viewMode = $0 }
                )) {
                    ForEach(SnippetLibraryViewMode.allCases) { mode in
                        Image(systemName: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 82)
                Menu {
                    Picker("Сортировка", selection: $sortRaw) {
                        ForEach(SnippetLibrarySort.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    Divider()
                    Button(sortAscending ? "По убыванию" : "По возрастанию") {
                        sortAscending.toggle()
                    }
                } label: {
                    Image(systemName: sortAscending ? "arrow.up.arrow.down.circle" : "arrow.down.arrow.up.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Сортировка")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(14)

            HStack(spacing: 6) {
                Button("Все сниппеты") { openRoot() }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedGroup == nil ? Color.primary : Color.accentColor)
                if let selectedGroup {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(selectedGroup.name).fontWeight(.semibold)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            ScrollView {
                if !normalizedQuery.isEmpty {
                    snippetCollection(searchResults, showsGroup: true)
                } else if let selectedGroup {
                    let snippets = sortedSnippets(store.templates(in: selectedGroup.id))
                    if snippets.isEmpty {
                        VStack(spacing: 14) {
                            ContentUnavailableView(
                                "Группа пуста",
                                systemImage: "folder",
                                description: Text("Добавьте первый сниппет в «\(selectedGroup.name)».")
                            )
                            Button("Новый сниппет", systemImage: "plus") {
                                presentEditor(nil, preferredGroupID: selectedGroup.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 70)
                    } else {
                        snippetCollection(snippets, showsGroup: false)
                    }
                } else if store.snippetGroups().isEmpty && ungroupedSnippets.isEmpty {
                    ContentUnavailableView(
                        "Сниппетов пока нет",
                        systemImage: "curlybraces",
                        description: Text("Создайте общую команду и назначьте ей SSH или Локальный терминал.")
                    )
                    .padding(.top, 70)
                } else {
                    groupCollection
                }
            }
            .background(Color.clear.contentShape(Rectangle()))
        }
    }

    @ViewBuilder
    private var groupCollection: some View {
        if viewMode == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(sortedGroups) { group in groupCard(group) }
                ForEach(sortedSnippets(ungroupedSnippets)) { snippet in
                    snippetCard(snippet, showsGroup: false)
                }
            }
            .padding(14)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(sortedGroups) { group in groupRow(group) }
                if !ungroupedSnippets.isEmpty {
                    Text("Без группы")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    ForEach(sortedSnippets(ungroupedSnippets)) { snippet in
                        snippetListButton(snippet, showsGroup: false)
                    }
                }
            }
            .padding(14)
        }
    }

    private func groupRow(_ group: TerminalSnippetGroup) -> some View {
        Button { openGroup(group.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(.headline)
                    Text("\(store.templates(in: group.id).count) сниппетов")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu { groupActions(group) }
    }

    private func groupCard(_ group: TerminalSnippetGroup) -> some View {
        Button { openGroup(group.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 8)
                Text(group.name).font(.headline).lineLimit(2)
                Text("\(store.templates(in: group.id).count) сниппетов")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .padding(16)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu { groupActions(group) }
    }

    @ViewBuilder
    private func groupActions(_ group: TerminalSnippetGroup) -> some View {
        Button("Открыть", systemImage: "folder") { openGroup(group.id) }
        Button("Новый сниппет", systemImage: "plus") {
            presentEditor(nil, preferredGroupID: group.id)
        }
        Divider()
        Button("Переименовать", systemImage: "pencil") {
            groupEditor = group
            groupEditorPresented = true
        }
        Button("Удалить группу", systemImage: "trash", role: .destructive) {
            _ = store.removeSnippetGroup(
                id: group.id,
                profileID: TerminalCommandHistoryStore.globalSnippetLibraryID
            )
        }
    }

    @ViewBuilder
    private func snippetCollection(
        _ snippets: [TerminalCommandTemplate],
        showsGroup: Bool
    ) -> some View {
        if snippets.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 70)
        } else if viewMode == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(snippets) { snippet in snippetCard(snippet, showsGroup: showsGroup) }
            }
            .padding(14)
        } else {
            LazyVStack(spacing: 7) {
                ForEach(snippets) { snippet in snippetListButton(snippet, showsGroup: showsGroup) }
            }
            .padding(14)
        }
    }

    private func snippetListButton(
        _ snippet: TerminalCommandTemplate,
        showsGroup: Bool
    ) -> some View {
        Button { selectSnippet(snippet.id) } label: {
            VStack(alignment: .leading, spacing: showsGroup ? 5 : 0) {
                snippetRow(snippet)
                if showsGroup {
                    Text(snippet.category).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .background(
                selectedSnippetID == snippet.id
                    ? Color.accentColor.opacity(0.15)
                    : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { _ = model.runTerminalSnippet(snippet) })
        .contextMenu { snippetActions(snippet) }
    }

    private func snippetCard(
        _ snippet: TerminalCommandTemplate,
        showsGroup: Bool
    ) -> some View {
        Button { selectSnippet(snippet.id) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: "curlybraces")
                        .font(.title2.bold()).foregroundStyle(Color.accentColor)
                    Spacer()
                    Label("\(snippet.targets.count)", systemImage: snippet.includesLocalTerminal ? "terminal" : "server.rack")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(snippet.title).font(.headline).lineLimit(2)
                Text(snippet.command.replacingOccurrences(of: "\n", with: " ↵ "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                if showsGroup {
                    Text(snippet.category).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(14)
            .background(
                selectedSnippetID == snippet.id
                    ? Color.accentColor.opacity(0.15)
                    : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { _ = model.runTerminalSnippet(snippet) })
        .contextMenu { snippetActions(snippet) }
    }

    @ViewBuilder
    private func snippetActions(_ snippet: TerminalCommandTemplate) -> some View {
        Button("Запустить", systemImage: "play.fill") { _ = model.runTerminalSnippet(snippet) }
        Button("Скопировать команду", systemImage: "doc.on.doc") { copyCommand(snippet.command) }
        Divider()
        Button("Изменить", systemImage: "pencil") { presentEditor(snippet) }
        Button("Дублировать", systemImage: "plus.square.on.square") {
            _ = store.duplicateTemplate(
                id: snippet.id,
                profileID: TerminalCommandHistoryStore.globalSnippetLibraryID
            )
        }
        Button("Новый сниппет в этой группе", systemImage: "plus") {
            presentEditor(nil, preferredGroupID: snippet.groupID)
        }
        Divider()
        Button("Удалить", systemImage: "trash", role: .destructive) { deleteSnippet = snippet }
    }

    private func snippetRow(_ snippet: TerminalCommandTemplate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "curlybraces")
                .font(.title3.bold())
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.title)
                    .font(.headline)
                Text(snippet.command.replacingOccurrences(of: "\n", with: " ↵ "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Label("\(snippet.targets.count)", systemImage: snippet.includesLocalTerminal ? "terminal" : "server.rack")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var inspector: some View {
        if let snippet = selectedSnippet {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snippet.title).font(.title2.bold())
                        Text(snippet.category).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { presentEditor(snippet) } label: {
                        Image(systemName: "pencil")
                    }
                    Button(role: .destructive) { deleteSnippet = snippet } label: {
                        Image(systemName: "trash")
                    }
                }

                GroupBox("Script") {
                    ScrollView {
                        Text(snippet.command)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 130)
                }

                GroupBox("Targets") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(targetProfiles(for: snippet)) { profile in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.friendlyName.isEmpty ? profile.host : profile.friendlyName)
                                    Text(profile.host)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "server.rack")
                            }
                        }
                        if snippet.includesLocalTerminal {
                            Label("Локальный терминал", systemImage: "terminal")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                if let summary = model.latestSnippetRun,
                   summary.snippetID == snippet.id {
                    GroupBox("Последний запуск") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(summary.targets) { target in
                                targetRunStatusRow(target)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }

                Spacer()
                Button {
                    _ = model.runTerminalSnippet(snippet)
                } label: {
                    Label("Запустить на \(snippet.targets.count) Targets", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(targetProfiles(for: snippet).isEmpty && !snippet.includesLocalTerminal)
            }
            .padding(22)
        } else {
            ContentUnavailableView("Выберите сниппет", systemImage: "curlybraces")
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    private var searchResults: [TerminalCommandTemplate] {
        guard !normalizedQuery.isEmpty else { return [] }
        return sortedSnippets(store.templates().filter { snippet in
            snippet.title.localizedLowercase.contains(normalizedQuery)
                || snippet.command.localizedLowercase.contains(normalizedQuery)
                || snippet.category.localizedLowercase.contains(normalizedQuery)
        })
    }

    private func targetProfiles(for snippet: TerminalCommandTemplate) -> [ConnectionProfile] {
        let ids = Set(snippet.targetProfileIDs)
        return sortedProfiles.filter { ids.contains($0.id) }
    }

    private func presentEditor(
        _ snippet: TerminalCommandTemplate?,
        preferredGroupID: UUID? = nil
    ) {
        editorRequest = TerminalSnippetEditorRequest(
            snippet: snippet,
            preferredGroupID: preferredGroupID
        )
    }

    private var sortedGroups: [TerminalSnippetGroup] {
        let groups = store.snippetGroups()
        return groups.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private var ungroupedSnippets: [TerminalCommandTemplate] {
        store.templates().filter { $0.groupID == TerminalCommandTemplate.legacyUnassignedGroupID }
    }

    private func sortedSnippets(_ snippets: [TerminalCommandTemplate]) -> [TerminalCommandTemplate] {
        snippets.sorted { lhs, rhs in
            let comparison: ComparisonResult
            if SnippetLibrarySort(rawValue: sortRaw) == .modified {
                comparison = lhs.updatedAt == rhs.updatedAt
                    ? lhs.title.localizedStandardCompare(rhs.title)
                    : (lhs.updatedAt < rhs.updatedAt ? .orderedAscending : .orderedDescending)
            } else {
                comparison = lhs.title.localizedStandardCompare(rhs.title)
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func openRoot() {
        selectedGroupID = nil
        persistedGroupID = ""
    }

    private func openGroup(_ id: UUID) {
        selectedGroupID = id
        persistedGroupID = id.uuidString
    }

    private func selectSnippet(_ id: UUID?) {
        selectedSnippetID = id
        persistedSnippetID = id?.uuidString ?? ""
    }

    private func restoreNavigation() {
        if let id = UUID(uuidString: persistedGroupID), store.snippetGroup(id: id) != nil {
            selectedGroupID = id
        }
        if let id = UUID(uuidString: persistedSnippetID), store.template(id: id) != nil {
            selectedSnippetID = id
        }
    }

    private func copyCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func runStatus(_ summary: TerminalSnippetRunSummary) -> some View {
        let sent = summary.targets.filter { $0.state == .sent }.count
        let connecting = summary.targets.filter { $0.state == .connecting }.count
        let failed = summary.targets.filter {
            if case .failed = $0.state { return true }
            return false
        }.count

        return HStack(spacing: 14) {
            Image(
                systemName: failed > 0
                    ? "exclamationmark.triangle.fill"
                    : (connecting > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
            )
            .foregroundStyle(failed > 0 ? Color.orange : (connecting > 0 ? Color.blue : Color.green))
            VStack(alignment: .leading, spacing: 3) {
                Text("Последний запуск · \(summary.title)")
                    .font(.subheadline.weight(.semibold))
                Text(summary.startedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if sent > 0 {
                Label("Отправлено: \(sent)", systemImage: "paperplane.fill")
                    .foregroundStyle(.green)
            }
            if connecting > 0 {
                Label("Подключение: \(connecting)", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
            }
            if failed > 0 {
                Label("Ошибки: \(failed)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.orange)
            }
            Button("Отключить SSH Targets") {
                showsDisconnectConfirmation = true
            }
            .disabled(summary.targets.isEmpty)
        }
        .font(.caption)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.07))
    }

    private func targetRunStatusRow(_ target: TerminalSnippetTargetRunStatus) -> some View {
        let details: (text: String, icon: String, color: Color) = switch target.state {
        case .connecting:
            ("Подключение…", "arrow.triangle.2.circlepath", .blue)
        case .sent:
            ("Команда отправлена", "paperplane.fill", .green)
        case .failed(let message):
            ("Ошибка: \(message)", "xmark.octagon.fill", .orange)
        }

        return HStack(spacing: 8) {
            Image(systemName: details.icon)
                .foregroundStyle(details.color)
            Text(target.name)
                .lineLimit(1)
            Spacer()
            Text(details.text)
                .font(.caption)
                .foregroundStyle(details.color)
                .lineLimit(2)
        }
    }
}

private struct TerminalSnippetEditorRequest: Identifiable {
    let id = UUID()
    let snippet: TerminalCommandTemplate?
    let preferredGroupID: UUID?
}

private struct TerminalSnippetDraft {
    let id: UUID?
    let title: String
    let command: String
    let category: String
    let groupID: UUID
    let targets: [TerminalSnippetTarget]

    var firstSSHProfileID: UUID? {
        for target in targets {
            if case .sshProfile(let id) = target { return id }
        }
        return nil
    }
}

private struct TerminalSnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let snippet: TerminalCommandTemplate?
    let preferredGroupID: UUID?
    let groups: [TerminalSnippetGroup]
    let profiles: [ConnectionProfile]
    let onSave: (TerminalSnippetDraft) -> Bool

    @State private var title: String
    @State private var command: String
    @State private var groupID: UUID
    @State private var targets: Set<TerminalSnippetTarget>
    @State private var saveError = ""

    init(
        snippet: TerminalCommandTemplate?,
        preferredGroupID: UUID?,
        groups: [TerminalSnippetGroup],
        profiles: [ConnectionProfile],
        onSave: @escaping (TerminalSnippetDraft) -> Bool
    ) {
        self.snippet = snippet
        self.preferredGroupID = preferredGroupID
        self.groups = groups
        self.profiles = profiles
        self.onSave = onSave
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _groupID = State(
            initialValue: snippet?.groupID
                ?? preferredGroupID
                ?? TerminalCommandTemplate.legacyUnassignedGroupID
        )
        _targets = State(initialValue: Set(snippet?.targets ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $title)
                Picker("Группа", selection: $groupID) {
                    Text("Без группы").tag(TerminalCommandTemplate.legacyUnassignedGroupID)
                    ForEach(groups) { group in Text(group.name).tag(group.id) }
                }
                Section("Команда или скрипт") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $command)
                            .font(.body.monospaced())
                            .frame(minHeight: 150)
                        if command.isEmpty {
                            Text("Введите команду или скрипт, например: docker ps")
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                }

                Section("Targets · до 8 целей") {
                    Toggle(isOn: targetBinding(.localTerminal)) {
                        Label("Локальный терминал", systemImage: "terminal")
                    }
                    .disabled(!targets.contains(.localTerminal) && targets.count >= 8)
                    ForEach(profiles) { profile in
                        Toggle(isOn: targetBinding(.sshProfile(profile.id))) {
                            VStack(alignment: .leading) {
                                Text(profile.friendlyName.isEmpty ? profile.host : profile.friendlyName)
                                Text(profile.host)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!targets.contains(.sshProfile(profile.id)) && targets.count >= 8)
                    }
                }

                if !saveError.isEmpty {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(snippet == nil ? "Новый сниппет" : "Изменить сниппет")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let draft = TerminalSnippetDraft(
                            id: snippet?.id,
                            title: title,
                            command: command,
                            category: groups.first(where: { $0.id == groupID })?.name ?? "",
                            groupID: groupID,
                            targets: orderedTargets
                        )
                        if onSave(draft) {
                            dismiss()
                        } else {
                            saveError = "Не удалось сохранить. Проверьте длину и убедитесь, что команда не содержит секреты."
                        }
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || targets.isEmpty
                    )
                }
            }
        }
        .frame(width: 620, height: 650)
    }

    private func targetBinding(_ target: TerminalSnippetTarget) -> Binding<Bool> {
        Binding(
            get: { targets.contains(target) },
            set: { selected in
                if selected { targets.insert(target) } else { targets.remove(target) }
            }
        )
    }

    private var orderedTargets: [TerminalSnippetTarget] {
        var result: [TerminalSnippetTarget] = []
        if targets.contains(.localTerminal) { result.append(.localTerminal) }
        for profile in profiles {
            let target = TerminalSnippetTarget.sshProfile(profile.id)
            if targets.contains(target) { result.append(target) }
        }
        return result
    }
}

private struct TerminalSnippetGroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let group: TerminalSnippetGroup?
    let onSave: (String) -> Void
    @State private var name: String

    init(group: TerminalSnippetGroup?, onSave: @escaping (String) -> Void) {
        self.group = group
        self.onSave = onSave
        _name = State(initialValue: group?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(group == nil ? "Новая группа" : "Переименовать группу")
                .font(.title2.bold())
            TextField("Название группы", text: $name)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    onSave(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
