import SwiftUI

enum SelectiveRemoteHostSelectionScope: String, Equatable {
    case personal
    case team
}

struct SelectiveRemoteHostSelectionItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let address: String
    let folder: String
    let context: String
    let scope: SelectiveRemoteHostSelectionScope

    init(id: UUID, title: String, address: String, folder: String,
         context: String = "", scope: SelectiveRemoteHostSelectionScope) {
        self.id = id
        self.title = title
        self.address = address
        self.folder = folder
        self.context = context
        self.scope = scope
    }

    init(profile: ConnectionProfile) {
        self.init(
            id: profile.id,
            title: profile.friendlyName.isEmpty ? profile.host : profile.friendlyName,
            address: profile.host,
            folder: profile.group,
            context: "",
            scope: .personal
        )
    }

    init(teamHost: SelectiveRemoteTeamHost) {
        self.init(
            id: teamHost.id, title: teamHost.profile.friendlyName,
            address: teamHost.address, folder: teamHost.profile.group,
            context: "\(teamHost.teamName) / \(teamHost.vaultName)", scope: .team
        )
    }
}

enum SelectiveRemoteHostSelectionModel {
    static func filtered(
        _ items: [SelectiveRemoteHostSelectionItem],
        query: String,
        scope: SelectiveRemoteHostSelectionScope?
    ) -> [SelectiveRemoteHostSelectionItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (scope == nil || item.scope == scope)
                && (search.isEmpty || [item.title, item.address, item.folder, item.context]
                    .contains { $0.localizedStandardContains(search) })
        }.sorted { lhs, rhs in
            if lhs.folder != rhs.folder {
                return lhs.folder.localizedStandardCompare(rhs.folder) == .orderedAscending
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    static func selectAllFiltered(current: Set<UUID>, visibleIDs: [UUID]) -> Set<UUID> {
        current.union(visibleIDs)
    }

    static func clearFiltered(current: Set<UUID>, visibleIDs: [UUID]) -> Set<UUID> {
        current.subtracting(visibleIDs)
    }

    static func clearAll(current: Set<UUID>) -> Set<UUID> {
        []
    }
}

struct SelectiveRemoteHostSelectionBrowser: View {
    enum Mode { case single, multi }

    let items: [SelectiveRemoteHostSelectionItem]
    let mode: Mode
    let scope: SelectiveRemoteHostSelectionScope?
    @Binding var selection: Set<UUID>
    var selectionLimit: Int? = nil
    var onCommit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var searchFocused: Bool

    private var visible: [SelectiveRemoteHostSelectionItem] {
        SelectiveRemoteHostSelectionModel.filtered(items, query: query, scope: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    UpdateLocalization.text(ru: "Поиск по имени, адресу или папке", en: "Search name, address, or folder"),
                    text: $query
                )
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onKeyPress(.return) { chooseHighlighted() }
                .onKeyPress(.escape) {
                    if let onCancel { onCancel() }
                    else if !query.isEmpty { query = "" }
                    else { searchFocused = false }
                    return .handled
                }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(UpdateLocalization.text(ru: "Очистить поиск", en: "Clear Search"))
                }
            }
            .padding(9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))

            if mode == .multi {
                HStack(spacing: 10) {
                    Text(UpdateLocalization.text(
                        ru: "Выбрано: \(selection.count)", en: "Selected: \(selection.count)"
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(UpdateLocalization.text(ru: "Выбрать найденные", en: "Select Filtered")) {
                        let allowed = selectionLimit.map { max(0, $0 - selection.count) }
                            ?? visible.count
                        selection = SelectiveRemoteHostSelectionModel.selectAllFiltered(
                            current: selection,
                            visibleIDs: Array(visible.map(\.id).filter { !selection.contains($0) }.prefix(allowed))
                        )
                    }
                    .disabled(visible.isEmpty || selectionLimit.map { selection.count >= $0 } == true)
                    Button(UpdateLocalization.text(ru: "Снять найденные", en: "Clear Filtered")) {
                        selection = SelectiveRemoteHostSelectionModel.clearFiltered(
                            current: selection, visibleIDs: visible.map(\.id)
                        )
                    }
                    .disabled(visible.isEmpty)
                    Button(UpdateLocalization.text(ru: "Сбросить всё", en: "Clear All")) {
                        selection = SelectiveRemoteHostSelectionModel.clearAll(current: selection)
                    }
                    .disabled(selection.isEmpty)
                }
                .buttonStyle(.link)
            }

            if items.isEmpty {
                ContentUnavailableView(
                    UpdateLocalization.text(ru: "Нет сохранённых Hosts", en: "No Saved Hosts"),
                    systemImage: "server.rack",
                    description: Text(UpdateLocalization.text(
                        ru: "Добавьте SSH Host, чтобы выбрать его здесь.",
                        en: "Add an SSH Host to select it here."
                    ))
                )
                .frame(minHeight: 130)
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(minHeight: 130)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    highlightedIndex = index
                                    choose(item)
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: mode == .multi
                                              ? (selection.contains(item.id) ? "checkmark.square.fill" : "square")
                                              : (selection.contains(item.id) ? "checkmark.circle.fill" : "circle"))
                                            .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title).font(.body.weight(.medium))
                                            Text(item.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                                            if !item.folder.isEmpty {
                                                Text(item.folder).font(.caption2).foregroundStyle(.secondary)
                                            }
                                            if !item.context.isEmpty {
                                                Text(item.context).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Text(item.scope == .team ? "Team" : "Personal")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        index == highlightedIndex ? Color.accentColor.opacity(0.11) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                    }
                    .onChange(of: highlightedIndex) { _, index in
                        if visible.indices.contains(index) { proxy.scrollTo(visible[index].id) }
                    }
                }
                .frame(minHeight: 150, maxHeight: 310)
            }
        }
        .padding(10)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !visible.isEmpty else { return .handled }
        highlightedIndex = max(0, min(visible.count - 1, highlightedIndex + delta))
        return .handled
    }

    private func chooseHighlighted() -> KeyPress.Result {
        guard visible.indices.contains(highlightedIndex) else { return .handled }
        choose(visible[highlightedIndex])
        return .handled
    }

    private func choose(_ item: SelectiveRemoteHostSelectionItem) {
        switch mode {
        case .single:
            selection = [item.id]
            onCommit?()
        case .multi:
            if selection.contains(item.id) { selection.remove(item.id) }
            else if selectionLimit.map({ selection.count < $0 }) ?? true {
                selection.insert(item.id)
            }
        }
    }
}
