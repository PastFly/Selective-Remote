import SwiftUI

struct TerminalSnippetsLibraryView: View {
    @ObservedObject var store: TerminalCommandHistoryStore
    @ObservedObject var model: AppModel

    @State private var query = ""
    @State private var selectedSnippetID: UUID?
    @State private var editorRequest: TerminalSnippetEditorRequest?
    @State private var groupEditor: TerminalSnippetGroup?
    @State private var groupEditorPresented = false
    @State private var deleteSnippet: TerminalCommandTemplate?
    @State private var showsDisconnectConfirmation = false

    private var selectedSnippet: TerminalCommandTemplate? {
        guard let selectedSnippetID else { return nil }
        return store.template(id: selectedSnippetID)
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
            HSplitView {
                libraryList
                    .frame(minWidth: 430, idealWidth: 620)
                inspector
                    .frame(minWidth: 320, idealWidth: 420)
            }
        }
        .sheet(item: $editorRequest) { request in
            TerminalSnippetEditorView(
                snippet: request.snippet,
                preferredGroup: request.preferredGroup,
                groups: store.snippetGroups(),
                profiles: sortedProfiles
            ) { draft in
                let profileID = draft.targetProfileIDs.first
                    ?? TerminalCommandHistoryStore.globalSnippetLibraryID
                if store.saveTemplate(
                    id: draft.id,
                    title: draft.title,
                    command: draft.command,
                    category: draft.category,
                    profileID: profileID,
                    targetProfileIDs: draft.targetProfileIDs
                ) {
                    selectedSnippetID = draft.id ?? store.templates().first?.id
                }
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
                    selectedSnippetID = store.templates().first?.id
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
            if selectedSnippetID == nil { selectedSnippetID = store.templates().first?.id }
        }
        .onChange(of: store.snippetRevision) { _, _ in
            if let selectedSnippetID, store.template(id: selectedSnippetID) == nil {
                self.selectedSnippetID = store.templates().first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Сниппеты")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Общая библиотека команд · один сниппет может запускаться на нескольких SSH Targets")
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
                presentEditor(nil)
            } label: {
                Label("Новый сниппет", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(sortedProfiles.isEmpty)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private var libraryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск сниппетов", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(14)

            List(selection: $selectedSnippetID) {
                ForEach(store.snippetGroups()) { group in
                    Section {
                        let snippets = filteredSnippets(in: group)
                        ForEach(snippets) { snippet in
                            snippetRow(snippet)
                                .tag(snippet.id)
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        _ = model.runTerminalSnippet(snippet)
                                    }
                                )
                                .contextMenu {
                                    Button("Запустить", systemImage: "play.fill") {
                                        _ = model.runTerminalSnippet(snippet)
                                    }
                                    Divider()
                                    Button("Изменить", systemImage: "pencil") {
                                        presentEditor(snippet)
                                    }
                                    Button("Дублировать", systemImage: "doc.on.doc") {
                                        _ = store.duplicateTemplate(
                                            id: snippet.id,
                                            profileID: TerminalCommandHistoryStore.globalSnippetLibraryID
                                        )
                                    }
                                    Button("Новый сниппет", systemImage: "plus") {
                                        presentEditor(nil, preferredGroup: group.name)
                                    }
                                    Divider()
                                    Button("Удалить", systemImage: "trash", role: .destructive) {
                                        deleteSnippet = snippet
                                    }
                                }
                        }
                        if snippets.isEmpty
                            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                presentEditor(nil, preferredGroup: group.name)
                            } label: {
                                Label("Новый сниппет", systemImage: "plus")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .padding(.vertical, 7)
                            .disabled(sortedProfiles.isEmpty)
                        }
                    } header: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text("\(store.templates().filter { $0.category == group.name }.count)")
                                .foregroundStyle(.secondary)
                            Menu {
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
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 28)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if store.snippetGroups().isEmpty {
                    ContentUnavailableView(
                        "Сниппетов пока нет",
                        systemImage: "curlybraces",
                        description: Text("Создайте общую команду и назначьте ей один или несколько SSH Targets.")
                    )
                }
            }
        }
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
            Label("\(snippet.targetProfileIDs.count)", systemImage: "server.rack")
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
                    Label("Запустить на \(snippet.targetProfileIDs.count) Targets", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(targetProfiles(for: snippet).isEmpty)
            }
            .padding(22)
        } else {
            ContentUnavailableView("Выберите сниппет", systemImage: "curlybraces")
        }
    }

    private func filteredSnippets(in group: TerminalSnippetGroup) -> [TerminalCommandTemplate] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        return store.templates().filter { snippet in
            guard snippet.category == group.name else { return false }
            return normalized.isEmpty
                || snippet.title.localizedLowercase.contains(normalized)
                || snippet.command.localizedLowercase.contains(normalized)
                || group.name.localizedLowercase.contains(normalized)
        }
    }

    private func targetProfiles(for snippet: TerminalCommandTemplate) -> [ConnectionProfile] {
        let ids = Set(snippet.targetProfileIDs)
        return sortedProfiles.filter { ids.contains($0.id) }
    }

    private func presentEditor(
        _ snippet: TerminalCommandTemplate?,
        preferredGroup: String? = nil
    ) {
        if store.snippetGroups().isEmpty {
            _ = store.createSnippetGroup(
                name: TerminalCommandHistoryStore.defaultSnippetGroupName,
                profileID: TerminalCommandHistoryStore.globalSnippetLibraryID
            )
        }
        editorRequest = TerminalSnippetEditorRequest(
            snippet: snippet,
            preferredGroup: preferredGroup
        )
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
    let preferredGroup: String?
}

private struct TerminalSnippetDraft {
    let id: UUID?
    let title: String
    let command: String
    let category: String
    let targetProfileIDs: [UUID]
}

private struct TerminalSnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let snippet: TerminalCommandTemplate?
    let preferredGroup: String?
    let groups: [TerminalSnippetGroup]
    let profiles: [ConnectionProfile]
    let onSave: (TerminalSnippetDraft) -> Void

    @State private var title: String
    @State private var command: String
    @State private var category: String
    @State private var targetIDs: Set<UUID>

    init(
        snippet: TerminalCommandTemplate?,
        preferredGroup: String?,
        groups: [TerminalSnippetGroup],
        profiles: [ConnectionProfile],
        onSave: @escaping (TerminalSnippetDraft) -> Void
    ) {
        self.snippet = snippet
        self.preferredGroup = preferredGroup
        self.groups = groups
        self.profiles = profiles
        self.onSave = onSave
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _category = State(
            initialValue: snippet?.category
                ?? preferredGroup
                ?? groups.first?.name
                ?? TerminalCommandHistoryStore.defaultSnippetGroupName
        )
        _targetIDs = State(initialValue: Set(snippet?.targetProfileIDs ?? profiles.first.map { [$0.id] } ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $title)
                Picker("Группа", selection: $category) {
                    ForEach(groups) { group in Text(group.name).tag(group.name) }
                }
                TextEditor(text: $command)
                    .font(.body.monospaced())
                    .frame(minHeight: 150)

                Section("Targets · до 8 SSH-профилей") {
                    ForEach(profiles) { profile in
                        Toggle(isOn: targetBinding(profile.id)) {
                            VStack(alignment: .leading) {
                                Text(profile.friendlyName.isEmpty ? profile.host : profile.friendlyName)
                                Text(profile.host)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!targetIDs.contains(profile.id) && targetIDs.count >= 8)
                    }
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
                        onSave(
                            TerminalSnippetDraft(
                                id: snippet?.id,
                                title: title,
                                command: command,
                                category: category,
                                targetProfileIDs: profiles.map(\.id).filter(targetIDs.contains)
                            )
                        )
                        dismiss()
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || targetIDs.isEmpty
                    )
                }
            }
        }
        .frame(width: 620, height: 650)
    }

    private func targetBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { targetIDs.contains(id) },
            set: { selected in
                if selected { targetIDs.insert(id) } else { targetIDs.remove(id) }
            }
        )
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
