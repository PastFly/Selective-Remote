import AppKit
import CryptoKit
import Foundation
import SwiftUI

enum SelectiveRemoteSnippetScope: String, CaseIterable, Identifiable {
    case personal
    case team

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personal: UpdateLocalization.text(ru: "Личные", en: "Personal")
        case .team: UpdateLocalization.text(ru: "Командные", en: "Team")
        }
    }
}

private enum SelectiveRemoteTeamSnippetSortMode: String, CaseIterable, Identifiable {
    case name
    case folder
    case modifiedNewest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: UpdateLocalization.text(ru: "По названию", en: "Name")
        case .folder: UpdateLocalization.text(ru: "По папке", en: "Folder")
        case .modifiedNewest: UpdateLocalization.text(ru: "Сначала новые", en: "Newest first")
        }
    }
}

struct SelectiveRemoteTeamSnippet: Identifiable, Equatable, Sendable {
    let id: UUID
    let recordID: UUID
    let teamID: UUID
    let teamName: String
    let role: SelectiveRemoteCloudTeamRole
    let vaultID: UUID
    let vaultName: String
    let revision: Int
    let keyGeneration: Int
    let modifiedAt: String
    let modifiedDate: Date
    let title: String
    let body: String
    let folder: String
}

struct SelectiveRemoteTeamSnippetVaultContext: Identifiable, Equatable, Sendable {
    let id: UUID
    let teamID: UUID
    let teamName: String
    let role: SelectiveRemoteCloudTeamRole
    let vaultID: UUID
    let vaultName: String

    var selectionKey: String {
        "\(teamID.canonicalCloudString)/\(vaultID.canonicalCloudString)"
    }
}

enum SelectiveRemoteTeamSnippetMaterializationError: Error, Equatable {
    case invalidSnapshot
    case invalidSnippetRecord
}

private struct SelectiveRemoteTeamSnippetFolderNode: Identifiable {
    let path: String
    let snippets: [SelectiveRemoteTeamSnippet]
    let children: [SelectiveRemoteTeamSnippetFolderNode]

    var id: String { path }
    var title: String { path.split(separator: "/").last.map(String.init) ?? path }
    var totalCount: Int {
        snippets.count + children.reduce(0) { $0 + $1.totalCount }
    }
}

enum SelectiveRemoteTeamSnippetMaterializer {
    static func materialize(
        _ snapshot: SelectiveRemoteTeamVaultMaterializedSnapshot
    ) throws -> [SelectiveRemoteTeamSnippet] {
        guard snapshot.teamID.isSelectiveRemoteCloudUUID,
              snapshot.vaultID.isSelectiveRemoteCloudUUID,
              snapshot.revision > 0,
              snapshot.keyGeneration > 0,
              validName(snapshot.teamName),
              validName(snapshot.vaultName)
        else { throw SelectiveRemoteTeamSnippetMaterializationError.invalidSnapshot }

        let document: SelectiveRemoteVaultDocument
        do {
            document = try SelectiveRemoteVaultDocument.decode(snapshot.payload)
        } catch {
            throw SelectiveRemoteTeamSnippetMaterializationError.invalidSnapshot
        }

        return try document.records.compactMap { record in
            guard record.type == .snippet else { return nil }
            guard case let .object(data) = record.data else {
                throw SelectiveRemoteTeamSnippetMaterializationError.invalidSnippetRecord
            }
            let keys = Set(data.keys)
            guard keys == Set(["title", "body"])
                    || keys == Set(["title", "body", "folder"]),
                  let title = string(data["title"]),
                  let body = string(data["body"]),
                  validTitle(title),
                  validBody(body),
                  let modifiedDate = timestamp(record.modifiedAt)
            else { throw SelectiveRemoteTeamSnippetMaterializationError.invalidSnippetRecord }
            let folder: String
            if data["folder"] != nil {
                guard let value = string(data["folder"]) else {
                    throw SelectiveRemoteTeamSnippetMaterializationError.invalidSnippetRecord
                }
                folder = value
            } else {
                folder = ""
            }
            guard validFolder(folder) else {
                throw SelectiveRemoteTeamSnippetMaterializationError.invalidSnippetRecord
            }

            return SelectiveRemoteTeamSnippet(
                id: scopedID(
                    teamID: snapshot.teamID,
                    vaultID: snapshot.vaultID,
                    recordID: record.id
                ),
                recordID: record.id,
                teamID: snapshot.teamID,
                teamName: snapshot.teamName,
                role: snapshot.role,
                vaultID: snapshot.vaultID,
                vaultName: snapshot.vaultName,
                revision: snapshot.revision,
                keyGeneration: snapshot.keyGeneration,
                modifiedAt: record.modifiedAt,
                modifiedDate: modifiedDate,
                title: title,
                body: body,
                folder: folder
            )
        }
    }

    static func scopedID(teamID: UUID, vaultID: UUID, recordID: UUID) -> UUID {
        let scope = [
            "selective-remote/team-snippet/v1",
            teamID.canonicalCloudString,
            vaultID.canonicalCloudString,
            recordID.canonicalCloudString
        ].joined(separator: "\u{0}")
        var bytes = Array(SHA256.hash(data: Data(scope.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func string(_ value: SelectiveRemoteJSONValue?) -> String? {
        guard case let .string(result) = value else { return nil }
        return result
    }

    private static func validName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && !value.isEmpty && value.count <= 120
            && !value.contains(where: { $0.isNewline })
    }

    private static func validTitle(_ value: String) -> Bool {
        validName(value)
    }

    private static func validBody(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32_768
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    && $0.value != 9
                    && $0.value != 10
                    && $0.value != 13
            })
    }

    private static func validFolder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && value.count <= 120
            && !value.contains(where: { $0.isNewline })
            && !value.hasPrefix("/")
            && !value.hasSuffix("/")
            && !value.contains("//")
    }

    private static func timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

@MainActor
final class SelectiveRemoteTeamSnippetStore: ObservableObject {
    static let shared = SelectiveRemoteTeamSnippetStore()

    @Published private(set) var snippets: [SelectiveRemoteTeamSnippet] = []
    @Published private(set) var vaults: [SelectiveRemoteTeamSnippetVaultContext] = []
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var synchronizedVaultCount = 0
    @Published private(set) var invalidVaultCount = 0

    private var snapshots: [String: SelectiveRemoteTeamVaultMaterializedSnapshot] = [:]

    init() {}

    func replace(
        with snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot],
        now: Date = Date()
    ) {
        self.snapshots = Dictionary(
            snapshots.map { (scopeKey(teamID: $0.teamID, vaultID: $0.vaultID), $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        rebuild(now: now)
    }

    func replaceVault(
        with snapshot: SelectiveRemoteTeamVaultMaterializedSnapshot,
        now: Date = Date()
    ) {
        snapshots[scopeKey(teamID: snapshot.teamID, vaultID: snapshot.vaultID)] = snapshot
        rebuild(now: now)
    }

    func clear() {
        replace(with: [])
    }

    private func rebuild(now: Date) {
        var nextSnippets: [SelectiveRemoteTeamSnippet] = []
        var nextVaults: [SelectiveRemoteTeamSnippetVaultContext] = []
        var invalid = 0
        for snapshot in snapshots.values {
            do {
                nextSnippets += try SelectiveRemoteTeamSnippetMaterializer.materialize(snapshot)
                nextVaults.append(.init(
                    id: SelectiveRemoteTeamSnippetMaterializer.scopedID(
                        teamID: snapshot.teamID,
                        vaultID: snapshot.vaultID,
                        recordID: snapshot.vaultID
                    ),
                    teamID: snapshot.teamID,
                    teamName: snapshot.teamName,
                    role: snapshot.role,
                    vaultID: snapshot.vaultID,
                    vaultName: snapshot.vaultName
                ))
            } catch {
                invalid += 1
            }
        }
        snippets = nextSnippets.sorted {
            let left = [$0.teamName, $0.vaultName, $0.title].map { $0.localizedLowercase }
            let right = [$1.teamName, $1.vaultName, $1.title].map { $0.localizedLowercase }
            return left == right
                ? $0.recordID.canonicalCloudString < $1.recordID.canonicalCloudString
                : left.lexicographicallyPrecedes(right)
        }
        vaults = nextVaults.sorted {
            [$0.teamName.localizedLowercase, $0.vaultName.localizedLowercase]
                .lexicographicallyPrecedes(
                    [$1.teamName.localizedLowercase, $1.vaultName.localizedLowercase]
                )
        }
        synchronizedVaultCount = snapshots.count - invalid
        invalidVaultCount = invalid
        lastUpdatedAt = snapshots.isEmpty ? nil : now
    }

    private func scopeKey(teamID: UUID, vaultID: UUID) -> String {
        "\(teamID.canonicalCloudString)/\(vaultID.canonicalCloudString)"
    }
}

@MainActor
struct SelectiveRemoteTeamSnippetsView: View {
    @ObservedObject var store: SelectiveRemoteTeamSnippetStore
    @ObservedObject var targetStore: SelectiveRemoteTeamSnippetTargetStore
    @ObservedObject var model: AppModel
    let createFolderRequest: Int
    let createRequest: Int

    @State private var query = ""
    @State private var selectedSnippetID: UUID?
    @State private var selectedVaultKey = ""
    @State private var selectedFolder: String?
    @State private var copiedSnippetID: UUID?
    @State private var targetEditorSnippet: SelectiveRemoteTeamSnippet?
    @State private var actionMessage = ""
    @State private var editorRequest: SelectiveRemoteTeamSnippetEditorRequest?
    @State private var folderEditorContext: SelectiveRemoteTeamSnippetVaultContext?
    @State private var snippetPendingDeletion: SelectiveRemoteTeamSnippet?
    @State private var showsVaultChooser = false
    @State private var showsFolderVaultChooser = false
    @State private var isMutating = false
    @State private var mutationMessage: SelectiveRemoteTeamSnippetMutationMessage?
    @AppStorage("SelectiveRemote.team-snippet.display-mode.v1")
    private var displayMode = ProfileCollectionDisplayMode.list
    @AppStorage("SelectiveRemote.team-snippet.sort-mode.v1")
    private var sortMode = SelectiveRemoteTeamSnippetSortMode.name
    @AppStorage("SelectiveRemote.team-snippet.collapsed-folders.v1")
    private var collapsedFoldersJSON = "[]"
    @AppStorage("SelectiveRemote.cloud.endpoint.v1")
    private var endpoint = SelectiveRemoteCloudEndpoint.production
    @AppStorage("SelectiveRemote.cloud.device-id.v1") private var storedDeviceID = ""

    private let identityManager = SelectiveRemoteTeamDeviceIdentityManager()

    init(
        store: SelectiveRemoteTeamSnippetStore,
        model: AppModel,
        targetStore: SelectiveRemoteTeamSnippetTargetStore = .shared,
        createFolderRequest: Int = 0,
        createRequest: Int = 0
    ) {
        self.store = store
        self.model = model
        self.targetStore = targetStore
        self.createFolderRequest = createFolderRequest
        self.createRequest = createRequest
    }

    private var writableVaults: [SelectiveRemoteTeamSnippetVaultContext] {
        store.vaults.filter {
            SelectiveRemoteTeamSnippetDocumentMutation.isWritable(role: $0.role)
        }
    }

    private var visibleSnippets: [SelectiveRemoteTeamSnippet] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.snippets.filter { snippet in
            (selectedVaultKey.isEmpty || vaultKey(snippet) == selectedVaultKey)
                && (selectedFolder.map {
                    snippet.folder == $0 || snippet.folder.hasPrefix("\($0)/")
                } ?? true)
                && (normalizedQuery.isEmpty || [
                    snippet.title, snippet.body, snippet.folder, snippet.teamName, snippet.vaultName
                ].contains { $0.localizedCaseInsensitiveContains(normalizedQuery) })
        }
        return filtered.sorted { left, right in
            switch sortMode {
            case .name:
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            case .folder:
                let folders = folderTitle(left.folder)
                    .localizedStandardCompare(folderTitle(right.folder))
                return folders == .orderedSame
                    ? left.title.localizedStandardCompare(right.title) == .orderedAscending
                    : folders == .orderedAscending
            case .modifiedNewest:
                return left.modifiedDate == right.modifiedDate
                    ? left.title.localizedStandardCompare(right.title) == .orderedAscending
                    : left.modifiedDate > right.modifiedDate
            }
        }
    }

    private var availableFolders: [String] {
        Array(Set(store.snippets.filter {
            selectedVaultKey.isEmpty || vaultKey($0) == selectedVaultKey
        }.map(\.folder))).sorted { folderTitle($0).localizedStandardCompare(folderTitle($1)) == .orderedAscending }
    }

    private var ungroupedVisibleSnippets: [SelectiveRemoteTeamSnippet] {
        visibleSnippets.filter { $0.folder.isEmpty }
    }

    private var folderTree: [SelectiveRemoteTeamSnippetFolderNode] {
        let grouped = Dictionary(grouping: visibleSnippets.filter { !$0.folder.isEmpty }, by: \.folder)
        var paths = Set(grouped.keys)
        for path in grouped.keys {
            let components = path.split(separator: "/").map(String.init)
            if components.count > 1 {
                for depth in 1 ..< components.count {
                    paths.insert(components.prefix(depth).joined(separator: "/"))
                }
            }
        }
        func children(of parent: String) -> [SelectiveRemoteTeamSnippetFolderNode] {
            paths.filter { folderParentPath($0) == parent }
                .sorted { folderLeafTitle($0).localizedStandardCompare(folderLeafTitle($1)) == .orderedAscending }
                .map { path in
                    SelectiveRemoteTeamSnippetFolderNode(
                        path: path,
                        snippets: grouped[path] ?? [],
                        children: children(of: path)
                    )
                }
        }
        return children(of: "")
    }

    private var selectedSnippet: SelectiveRemoteTeamSnippet? {
        visibleSnippets.first(where: { $0.id == selectedSnippetID })
    }

    var body: some View {
        GeometryReader { proxy in
            HSplitView {
                VStack(spacing: 0) {
                    controls
                    Divider()
                    if store.snippets.isEmpty {
                        ContentUnavailableView(
                            UpdateLocalization.text(
                                ru: "Team Snippets пока не синхронизированы",
                                en: "Team Snippets Have Not Synchronized Yet"
                            ),
                            systemImage: "curlybraces",
                            description: Text(UpdateLocalization.text(
                                ru: "Разблокируйте приложение и дождитесь безопасной синхронизации Team Vault.",
                                en: "Unlock the app and wait for secure Team Vault synchronization."
                            ))
                        )
                    } else if visibleSnippets.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        if displayMode == .list {
                            List(selection: $selectedSnippetID) {
                                if !ungroupedVisibleSnippets.isEmpty {
                                    DisclosureGroup(
                                        isExpanded: folderExpansionBinding(for: "")
                                    ) {
                                        ForEach(ungroupedVisibleSnippets) { snippet in
                                            snippetRow(snippet)
                                                .tag(snippet.id)
                                                .contextMenu { snippetActions(snippet) }
                                        }
                                    } label: {
                                        folderDisclosureLabel(
                                            path: "",
                                            title: folderTitle(""),
                                            count: ungroupedVisibleSnippets.count
                                        )
                                    }
                                }
                                ForEach(folderTree) { node in teamSnippetListFolder(node) }
                            }
                            .listStyle(.inset)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 14) {
                                    if !ungroupedVisibleSnippets.isEmpty {
                                        DisclosureGroup(
                                            isExpanded: folderExpansionBinding(for: "")
                                        ) {
                                            LazyVGrid(
                                                columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                                                alignment: .leading,
                                                spacing: 12
                                            ) {
                                                ForEach(ungroupedVisibleSnippets) { snippet in
                                                    snippetGridCard(snippet)
                                                }
                                            }
                                            .padding(.top, 10)
                                        } label: {
                                            folderDisclosureLabel(
                                                path: "",
                                                title: folderTitle(""),
                                                count: ungroupedVisibleSnippets.count
                                            )
                                                .padding(.vertical, 4)
                                        }
                                    }
                                    ForEach(folderTree) { node in teamSnippetGridFolder(node) }
                                }
                                .padding(14)
                            }
                        }
                    }
                    Divider()
                    status
                }
                .frame(minWidth: 340, idealWidth: max(400, proxy.size.width * 0.42))

                Group {
                    if let selectedSnippet {
                        inspector(selectedSnippet)
                    } else {
                        ContentUnavailableView(
                            UpdateLocalization.text(ru: "Выберите Team Snippet", en: "Select a Team Snippet"),
                            systemImage: "curlybraces"
                        )
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { normalizeSelection() }
        .onChange(of: store.snippets.map(\.id)) { _, _ in normalizeSelection() }
        .onChange(of: selectedVaultKey) { _, _ in normalizeSelection() }
        .onChange(of: selectedFolder) { _, _ in normalizeSelection() }
        .onChange(of: selectedSnippetID) { _, _ in actionMessage = "" }
        .onChange(of: createRequest) { _, _ in presentCreateEditor() }
        .onChange(of: createFolderRequest) { _, _ in presentCreateFolderEditor() }
        .sheet(item: $targetEditorSnippet) { snippet in
            SelectiveRemoteTeamSnippetTargetsEditor(
                snippet: snippet,
                profiles: availableProfiles,
                selectedProfileIDs: targetStore.targets(for: snippet.id)
            ) { profileIDs in
                targetStore.setTargets(profileIDs, for: snippet.id)
                actionMessage = UpdateLocalization.text(
                    ru: "Назначения сохранены только на этом Mac",
                    en: "Targets saved on this Mac only"
                )
            }
        }
        .sheet(item: $editorRequest) { request in
            SelectiveRemoteTeamSnippetEditorView(request: request) { recordID, title, body, folder in
                mutate(
                    request.snippet.map {
                        .update(recordID: $0.recordID, title: title, body: body, folder: folder)
                    } ?? .create(recordID: recordID, title: title, body: body, folder: folder),
                    context: request.context,
                    selectedRecordID: recordID
                )
            }
        }
        .sheet(item: $folderEditorContext) { context in
            SelectiveRemoteTeamSnippetFolderEditor(context: context) { folder in
                editorRequest = .init(
                    context: context,
                    snippet: nil,
                    preferredFolder: folder
                )
            }
        }
        .confirmationDialog(
            UpdateLocalization.text(ru: "Выберите Team Vault", en: "Choose a Team Vault"),
            isPresented: $showsVaultChooser
        ) {
            ForEach(writableVaults) { vault in
                Button("\(vault.teamName) / \(vault.vaultName)") {
                    editorRequest = .init(context: vault, snippet: nil)
                }
            }
            Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            UpdateLocalization.text(ru: "Выберите Team Vault для группы", en: "Choose a Team Vault for the Folder"),
            isPresented: $showsFolderVaultChooser
        ) {
            ForEach(writableVaults) { vault in
                Button("\(vault.teamName) / \(vault.vaultName)") {
                    folderEditorContext = vault
                }
            }
            Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            UpdateLocalization.text(ru: "Удалить Team Snippet?", en: "Delete Team Snippet?"),
            isPresented: Binding(
                get: { snippetPendingDeletion != nil },
                set: { if !$0 { snippetPendingDeletion = nil } }
            ),
            presenting: snippetPendingDeletion
        ) { snippet in
            Button(UpdateLocalization.text(ru: "Удалить", en: "Delete"), role: .destructive) {
                if let context = context(for: snippet) {
                    mutate(
                        .delete(recordID: snippet.recordID),
                        context: context,
                        selectedRecordID: nil
                    )
                }
                snippetPendingDeletion = nil
            }
            Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), role: .cancel) {}
        } message: { snippet in
            Text(snippet.title)
        }
        .alert(item: $mutationMessage) { value in
            Alert(
                title: Text(value.isError
                    ? UpdateLocalization.text(ru: "Team Snippet не изменён", en: "Team Snippet Not Changed")
                    : UpdateLocalization.text(ru: "Team Snippet обновлён", en: "Team Snippet Updated")
                ),
                message: Text(value.text),
                dismissButton: .default(Text("OK"))
            )
        }
        .overlay {
            if isMutating {
                ZStack {
                    Color.black.opacity(0.12)
                    ProgressView(UpdateLocalization.text(
                        ru: "Шифрование и синхронизация…",
                        en: "Encrypting and synchronizing…"
                    ))
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    UpdateLocalization.text(ru: "Название, команда или текст", en: "Title, Team, or command"),
                    text: $query
                )
                .textFieldStyle(.plain)
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(query.isEmpty ? 0 : 1)
                .disabled(query.isEmpty)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Menu {
                    Button(UpdateLocalization.text(ru: "Все Team Vaults", en: "All Team Vaults")) {
                        selectedVaultKey = ""
                    }
                    if !store.vaults.isEmpty { Divider() }
                    ForEach(store.vaults) { vault in
                        Button("\(vault.teamName) / \(vault.vaultName)") {
                            selectedVaultKey = vault.selectionKey
                        }
                    }
                } label: {
                    Label(selectedVaultTitle, systemImage: "tray.full")
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button(UpdateLocalization.text(ru: "Все папки", en: "All Folders")) {
                        selectedFolder = nil
                    }
                    if !availableFolders.isEmpty { Divider() }
                    ForEach(availableFolders, id: \.self) { folder in
                        Button(folderTitle(folder)) { selectedFolder = folder }
                    }
                } label: {
                    Label(
                        selectedFolder.map(folderTitle)
                            ?? UpdateLocalization.text(ru: "Все папки", en: "All Folders"),
                        systemImage: "folder"
                    )
                }
                .menuStyle(.borderlessButton)

                Spacer()

                ProfileCollectionDisplayModePicker(selection: $displayMode)

                Menu {
                    Picker(UpdateLocalization.text(ru: "Сортировка", en: "Sort"), selection: $sortMode) {
                        ForEach(SelectiveRemoteTeamSnippetSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .help(UpdateLocalization.text(ru: "Сортировка", en: "Sort"))

                Menu {
                    ForEach(writableVaults) { vault in
                        Button("\(vault.teamName) / \(vault.vaultName)") {
                            editorRequest = .init(context: vault, snippet: nil)
                        }
                    }
                } label: {
                    Label(
                        UpdateLocalization.text(ru: "Добавить", en: "Add"),
                        systemImage: "plus"
                    )
                }
                .menuStyle(.borderlessButton)
                .disabled(writableVaults.isEmpty || isMutating)
                Text("\(visibleSnippets.count) \(UpdateLocalization.text(ru: "из", en: "of")) \(store.snippets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func snippetRow(_ snippet: SelectiveRemoteTeamSnippet) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(snippet.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(snippet.role.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(snippetLocation(snippet))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(snippet.body.replacingOccurrences(of: "\n", with: " "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Label(targetCountTitle(for: snippet), systemImage: "server.rack")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var collapsedFolders: Set<String> {
        guard let data = collapsedFoldersJSON.data(using: .utf8),
              let folders = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(folders)
    }

    private func folderExpansionBinding(for folder: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(folder) },
            set: { expanded in
                var folders = collapsedFolders
                if expanded { folders.remove(folder) } else { folders.insert(folder) }
                guard let data = try? JSONEncoder().encode(folders.sorted()),
                      let value = String(data: data, encoding: .utf8)
                else { return }
                collapsedFoldersJSON = value
            }
        )
    }

    private func folderDisclosureLabel(path: String, title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func teamSnippetListFolder(
        _ node: SelectiveRemoteTeamSnippetFolderNode
    ) -> AnyView {
        AnyView(
            DisclosureGroup(isExpanded: folderExpansionBinding(for: node.path)) {
                ForEach(node.children) { child in teamSnippetListFolder(child) }
                ForEach(node.snippets) { snippet in
                    snippetRow(snippet)
                        .tag(snippet.id)
                        .contextMenu { snippetActions(snippet) }
                }
            } label: {
                folderDisclosureLabel(path: node.path, title: node.title, count: node.totalCount)
            }
        )
    }

    private func teamSnippetGridFolder(
        _ node: SelectiveRemoteTeamSnippetFolderNode
    ) -> AnyView {
        AnyView(
            DisclosureGroup(isExpanded: folderExpansionBinding(for: node.path)) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(node.children) { child in teamSnippetGridFolder(child) }
                    if !node.snippets.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(node.snippets) { snippet in snippetGridCard(snippet) }
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 12)
            } label: {
                folderDisclosureLabel(path: node.path, title: node.title, count: node.totalCount)
                    .padding(.vertical, 4)
            }
        )
    }

    private func folderParentPath(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }

    private func folderLeafTitle(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func snippetGridCard(_ snippet: SelectiveRemoteTeamSnippet) -> some View {
        Button {
            selectedSnippetID = snippet.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "curlybraces")
                        .foregroundStyle(Color.accentColor)
                    Text(snippet.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                }
                Text(snippetLocation(snippet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(snippet.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Label(targetCountTitle(for: snippet), systemImage: "server.rack")
                    Spacer()
                    Text(snippet.role.localizedTitle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(
                selectedSnippetID == snippet.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        selectedSnippetID == snippet.id ? Color.accentColor : Color.secondary.opacity(0.18)
                    )
            }
        }
        .buttonStyle(.plain)
        .contextMenu { snippetActions(snippet) }
    }

    private func inspector(_ snippet: SelectiveRemoteTeamSnippet) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "curlybraces")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(snippet.title)
                        .font(.title2.bold())
                    Text(snippetLocation(snippet))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if SelectiveRemoteTeamSnippetDocumentMutation.isWritable(role: snippet.role) {
                    Button {
                        if let context = context(for: snippet) {
                            editorRequest = .init(context: context, snippet: snippet)
                        }
                    } label: {
                        Label(
                            UpdateLocalization.text(ru: "Изменить", en: "Edit"),
                            systemImage: "pencil"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isMutating)
                    Button(role: .destructive) {
                        snippetPendingDeletion = snippet
                    } label: {
                        Label(
                            UpdateLocalization.text(ru: "Удалить", en: "Delete"),
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isMutating)
                }
                Button {
                    targetEditorSnippet = snippet
                } label: {
                    Label(
                        UpdateLocalization.text(ru: "Хосты", en: "Targets"),
                        systemImage: "server.rack"
                    )
                }
                .buttonStyle(.bordered)
                Button {
                    copy(snippet)
                } label: {
                    Label(
                        copiedSnippetID == snippet.id
                            ? UpdateLocalization.text(ru: "Скопировано", en: "Copied")
                            : UpdateLocalization.text(ru: "Копировать", en: "Copy"),
                        systemImage: copiedSnippetID == snippet.id ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 18) {
                Label(snippet.role.localizedTitle, systemImage: "person.badge.shield.checkmark")
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Label(
                        modifiedRelativeTitle(snippet.modifiedDate, now: context.date),
                        systemImage: "clock"
                    )
                    .help(snippet.modifiedDate.formatted(date: .abbreviated, time: .standard))
                }
                Label("r\(snippet.revision) · k\(snippet.keyGeneration)", systemImage: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GroupBox(UpdateLocalization.text(ru: "Назначенные хосты", en: "Assigned Targets")) {
                VStack(alignment: .leading, spacing: 8) {
                    let profiles = targetProfiles(for: snippet)
                    if profiles.isEmpty {
                        Text(UpdateLocalization.text(
                            ru: "Хосты ещё не выбраны. Назначение является личной настройкой на этом Mac.",
                            en: "No targets selected. Assignment is a personal setting on this Mac."
                        ))
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(profiles) { profile in
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            if !actionMessage.isEmpty {
                Text(actionMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }

            if let summary = model.latestSnippetRun, summary.snippetID == snippet.id {
                GroupBox(UpdateLocalization.text(ru: "Последний запуск", en: "Latest Run")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.targets) { target in
                            HStack {
                                Image(systemName: runStateIcon(target.state))
                                    .foregroundStyle(runStateColor(target.state))
                                Text(target.name)
                                Spacer()
                                Text(runStateTitle(target.state))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }

            ScrollView {
                Text(snippet.body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            Label(
                UpdateLocalization.text(
                    ru: "Команда показывается только в памяти после расшифровки Team Vault. Она не запускается автоматически: копирование и запуск выполняются только по вашему нажатию.",
                    en: "The command exists only in memory after Team Vault decryption. It never runs automatically; copying and running require your explicit action."
                ),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                run(snippet)
            } label: {
                Label(
                    UpdateLocalization.text(
                        ru: "Запустить на \(targetProfiles(for: snippet).count) хостах",
                        en: "Run on \(targetProfiles(for: snippet).count) Targets"
                    ),
                    systemImage: "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(targetProfiles(for: snippet).isEmpty)
        }
        .padding(24)
    }

    private var status: some View {
        HStack(spacing: 10) {
            if let lastUpdatedAt = store.lastUpdatedAt {
                Label {
                    Text(lastUpdatedAt, style: .time)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            Text(UpdateLocalization.text(
                ru: "Team Vaults: \(store.synchronizedVaultCount)",
                en: "Team Vaults: \(store.synchronizedVaultCount)"
            ))
            if store.invalidVaultCount > 0 {
                Label("\(store.invalidVaultCount)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(UpdateLocalization.text(
                        ru: "Некорректные Team Snippets скрыты целиком",
                        en: "Invalid Team Snippets are hidden in full"
                    ))
            }
            Spacer()
            Text(UpdateLocalization.text(ru: "Только в памяти", en: "Memory only"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
    }

    private var selectedVaultTitle: String {
        guard let vault = store.vaults.first(where: { $0.selectionKey == selectedVaultKey }) else {
            return UpdateLocalization.text(ru: "Все Team Vaults", en: "All Team Vaults")
        }
        return "\(vault.teamName) / \(vault.vaultName)"
    }

    private func folderTitle(_ folder: String) -> String {
        folder.isEmpty
            ? UpdateLocalization.text(ru: "Без папки", en: "No Folder")
            : folder
    }

    private func snippetLocation(_ snippet: SelectiveRemoteTeamSnippet) -> String {
        "\(snippet.teamName) / \(snippet.vaultName) · \(folderTitle(snippet.folder))"
    }

    private func vaultKey(_ snippet: SelectiveRemoteTeamSnippet) -> String {
        "\(snippet.teamID.canonicalCloudString)/\(snippet.vaultID.canonicalCloudString)"
    }

    private func normalizeSelection() {
        if !selectedVaultKey.isEmpty,
           !store.vaults.contains(where: { $0.selectionKey == selectedVaultKey }) {
            selectedVaultKey = ""
        }
        if let selectedFolder, !availableFolders.contains(selectedFolder) {
            self.selectedFolder = nil
        }
        if selectedSnippet == nil {
            selectedSnippetID = visibleSnippets.first?.id
        }
    }

    private func copy(_ snippet: SelectiveRemoteTeamSnippet) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet.body, forType: .string)
        copiedSnippetID = snippet.id
    }

    @ViewBuilder
    private func snippetActions(_ snippet: SelectiveRemoteTeamSnippet) -> some View {
        if SelectiveRemoteTeamSnippetDocumentMutation.isWritable(role: snippet.role) {
            Button(UpdateLocalization.text(ru: "Изменить…", en: "Edit…"), systemImage: "pencil") {
                if let context = context(for: snippet) {
                    editorRequest = .init(context: context, snippet: snippet)
                }
            }
            Button(
                UpdateLocalization.text(ru: "Удалить", en: "Delete"),
                systemImage: "trash",
                role: .destructive
            ) {
                snippetPendingDeletion = snippet
            }
            Divider()
        }
        Button(UpdateLocalization.text(ru: "Запустить", en: "Run"), systemImage: "play.fill") {
            run(snippet)
        }
        .disabled(targetProfiles(for: snippet).isEmpty)
        Button(
            UpdateLocalization.text(ru: "Настроить хосты…", en: "Configure Targets…"),
            systemImage: "server.rack"
        ) {
            targetEditorSnippet = snippet
        }
        Divider()
        Button(
            UpdateLocalization.text(ru: "Скопировать команду", en: "Copy Command"),
            systemImage: "doc.on.doc"
        ) {
            copy(snippet)
        }
    }

    private func presentCreateEditor() {
        if writableVaults.count == 1, let vault = writableVaults.first {
            editorRequest = .init(context: vault, snippet: nil)
        } else if !writableVaults.isEmpty {
            showsVaultChooser = true
        } else {
            mutationMessage = .init(
                text: UpdateLocalization.text(
                    ru: "Нет доступного Team Vault с ролью Owner, Admin или Editor.",
                    en: "No Team Vault is available with the Owner, Admin, or Editor role."
                ),
                isError: true
            )
        }
    }

    private func presentCreateFolderEditor() {
        if writableVaults.count == 1, let vault = writableVaults.first {
            folderEditorContext = vault
        } else if !writableVaults.isEmpty {
            showsFolderVaultChooser = true
        } else {
            mutationMessage = .init(
                text: UpdateLocalization.text(
                    ru: "Нет доступного Team Vault с ролью Owner, Admin или Editor.",
                    en: "No Team Vault is available with the Owner, Admin, or Editor role."
                ),
                isError: true
            )
        }
    }

    private func context(
        for snippet: SelectiveRemoteTeamSnippet
    ) -> SelectiveRemoteTeamSnippetVaultContext? {
        store.vaults.first {
            $0.teamID == snippet.teamID && $0.vaultID == snippet.vaultID
        }
    }

    private func mutate(
        _ change: SelectiveRemoteTeamSnippetMutationChange,
        context: SelectiveRemoteTeamSnippetVaultContext,
        selectedRecordID: UUID?
    ) {
        guard !isMutating else { return }
        isMutating = true
        Task { @MainActor in
            defer { isMutating = false }
            do {
                let url = try SelectiveRemoteCloudEndpoint.normalized(endpoint)
                let identity = try await identityManager.identity(
                    endpoint: url,
                    deviceID: resolvedDeviceID()
                )
                let service = try SelectiveRemoteTeamSnippetMutationService()
                let snapshot = try await service.apply(
                    change,
                    to: context,
                    endpoint: url,
                    identity: identity
                )
                store.replaceVault(with: snapshot)
                if let selectedRecordID {
                    selectedSnippetID = SelectiveRemoteTeamSnippetMaterializer.scopedID(
                        teamID: context.teamID,
                        vaultID: context.vaultID,
                        recordID: selectedRecordID
                    )
                } else {
                    selectedSnippetID = nil
                }
                mutationMessage = .init(
                    text: UpdateLocalization.text(
                        ru: "Зашифрованная ревизия Team Vault синхронизирована.",
                        en: "The encrypted Team Vault revision was synchronized."
                    ),
                    isError: false
                )
            } catch {
                mutationMessage = .init(text: error.localizedDescription, isError: true)
            }
        }
    }

    private func resolvedDeviceID() -> UUID {
        if let value = UUID(uuidString: storedDeviceID), value.isSelectiveRemoteCloudUUID {
            return value
        }
        let value = UUID()
        storedDeviceID = value.canonicalCloudString
        return value
    }

    private var availableProfiles: [ConnectionProfile] {
        model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                let left = $0.friendlyName.isEmpty ? $0.host : $0.friendlyName
                let right = $1.friendlyName.isEmpty ? $1.host : $1.friendlyName
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }

    private func targetProfiles(for snippet: SelectiveRemoteTeamSnippet) -> [ConnectionProfile] {
        let ids = Set(targetStore.targets(for: snippet.id))
        return availableProfiles.filter { ids.contains($0.id) }
    }

    private func targetCountTitle(for snippet: SelectiveRemoteTeamSnippet) -> String {
        UpdateLocalization.text(
            ru: "Хостов: \(targetProfiles(for: snippet).count)",
            en: "Targets: \(targetProfiles(for: snippet).count)"
        )
    }

    private func run(_ snippet: SelectiveRemoteTeamSnippet) {
        let profiles = targetProfiles(for: snippet)
        guard let first = profiles.first else {
            actionMessage = UpdateLocalization.text(
                ru: "Сначала выберите хосты для запуска",
                en: "Select targets before running"
            )
            targetEditorSnippet = snippet
            return
        }
        let executable = TerminalCommandTemplate(
            id: snippet.id,
            profileID: first.id,
            title: snippet.title,
            command: snippet.body,
            category: snippetLocation(snippet),
            targets: profiles.map { .sshProfile($0.id) },
            updatedAt: snippet.modifiedDate
        )
        switch model.runTerminalSnippet(executable) {
        case .success:
            actionMessage = UpdateLocalization.text(ru: "Команда отправлена", en: "Command sent")
        case .connecting:
            actionMessage = UpdateLocalization.text(
                ru: "Подключение к хостам и запуск команды…",
                en: "Connecting to targets and running command…"
            )
        case .noTargets:
            actionMessage = UpdateLocalization.text(ru: "Доступные хосты не найдены", en: "No targets available")
        case .inactiveSession:
            actionMessage = UpdateLocalization.text(ru: "SSH-сессия недоступна", en: "SSH session unavailable")
        case .invalidSnippet:
            actionMessage = UpdateLocalization.text(ru: "Команда некорректна", en: "Invalid command")
        }
    }

    private func runStateTitle(_ state: TerminalSnippetTargetRunState) -> String {
        switch state {
        case .connecting: UpdateLocalization.text(ru: "Подключение", en: "Connecting")
        case .sent: UpdateLocalization.text(ru: "Отправлено", en: "Sent")
        case .failed(let message): message
        }
    }

    private func runStateIcon(_ state: TerminalSnippetTargetRunState) -> String {
        switch state {
        case .connecting: "clock.arrow.circlepath"
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func runStateColor(_ state: TerminalSnippetTargetRunState) -> Color {
        switch state {
        case .connecting: .orange
        case .sent: .green
        case .failed: .red
        }
    }

    private func modifiedRelativeTitle(_ date: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 {
            return UpdateLocalization.text(ru: "Изменён только что", en: "Modified just now")
        }
        if elapsed < 3_600 {
            let minutes = max(1, elapsed / 60)
            let russian = russianUnit(minutes, one: "минуту", few: "минуты", many: "минут")
            let english = minutes == 1 ? "minute" : "minutes"
            return UpdateLocalization.text(
                ru: "Изменён \(minutes) \(russian) назад",
                en: "Modified \(minutes) \(english) ago"
            )
        }
        if elapsed < 86_400 {
            let hours = max(1, elapsed / 3_600)
            let russian = russianUnit(hours, one: "час", few: "часа", many: "часов")
            let english = hours == 1 ? "hour" : "hours"
            return UpdateLocalization.text(
                ru: "Изменён \(hours) \(russian) назад",
                en: "Modified \(hours) \(english) ago"
            )
        }
        let days = max(1, elapsed / 86_400)
        let russian = russianUnit(days, one: "день", few: "дня", many: "дней")
        let english = days == 1 ? "day" : "days"
        return UpdateLocalization.text(
            ru: "Изменён \(days) \(russian) назад",
            en: "Modified \(days) \(english) ago"
        )
    }

    private func russianUnit(_ value: Int, one: String, few: String, many: String) -> String {
        let lastTwo = value % 100
        if (11 ... 14).contains(lastTwo) { return many }
        switch value % 10 {
        case 1: return one
        case 2 ... 4: return few
        default: return many
        }
    }
}

private struct SelectiveRemoteTeamSnippetFolderEditor: View {
    let context: SelectiveRemoteTeamSnippetVaultContext
    let onContinue: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""

    private var normalizedFolder: String {
        folder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        folder == normalizedFolder
            && !folder.isEmpty
            && folder.count <= 120
            && !folder.hasPrefix("/")
            && !folder.hasSuffix("/")
            && !folder.contains("//")
            && !folder.contains(where: { $0.isNewline })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(UpdateLocalization.text(ru: "Новая группа", en: "New Folder"))
                .font(.title2.bold())
            Text("\(context.teamName) / \(context.vaultName)")
                .foregroundStyle(.secondary)
            TextField(
                UpdateLocalization.text(
                    ru: "Путь, например Production/Deploy",
                    en: "Path, for example Production/Deploy"
                ),
                text: $folder
            )
            .textFieldStyle(.roundedBorder)
            Text(UpdateLocalization.text(
                ru: "После выбора пути откроется создание первого сниппета. Группа появится у всей команды после зашифрованной синхронизации.",
                en: "After choosing the path, create its first snippet. The folder appears for the team after encrypted synchronization."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel")) { dismiss() }
                Button(UpdateLocalization.text(ru: "Продолжить", en: "Continue")) {
                    dismiss()
                    DispatchQueue.main.async { onContinue(folder) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct SelectiveRemoteTeamSnippetTargetsEditor: View {
    let snippet: SelectiveRemoteTeamSnippet
    let profiles: [ConnectionProfile]
    let onSave: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfileIDs: Set<UUID>

    init(
        snippet: SelectiveRemoteTeamSnippet,
        profiles: [ConnectionProfile],
        selectedProfileIDs: [UUID],
        onSave: @escaping ([UUID]) -> Void
    ) {
        self.snippet = snippet
        self.profiles = profiles
        self.onSave = onSave
        _selectedProfileIDs = State(initialValue: Set(selectedProfileIDs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(UpdateLocalization.text(ru: "Хосты для Team Snippet", en: "Team Snippet Targets"))
                    .font(.title2.bold())
                Text(snippet.title)
                    .foregroundStyle(.secondary)
                Text(UpdateLocalization.text(
                    ru: "Выбор хранится только на этом Mac и не изменяет общий Team Vault.",
                    en: "This selection is stored only on this Mac and does not change the shared Team Vault."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if profiles.isEmpty {
                ContentUnavailableView(
                    UpdateLocalization.text(ru: "Нет личных SSH-хостов", en: "No Personal SSH Hosts"),
                    systemImage: "server.rack",
                    description: Text(UpdateLocalization.text(
                        ru: "Добавьте SSH-хост, чтобы назначить его для запуска.",
                        en: "Add an SSH host before assigning a target."
                    ))
                )
            } else {
                List(profiles) { profile in
                    Toggle(isOn: targetBinding(profile.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.friendlyName.isEmpty ? profile.host : profile.friendlyName)
                            Text(profile.host)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.inset)
            }

            HStack {
                Button(UpdateLocalization.text(ru: "Снять выбор", en: "Clear")) {
                    selectedProfileIDs.removeAll()
                }
                .disabled(selectedProfileIDs.isEmpty)
                Spacer()
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel")) { dismiss() }
                Button(UpdateLocalization.text(ru: "Сохранить", en: "Save")) {
                    onSave(Array(selectedProfileIDs))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 520)
    }

    private func targetBinding(_ profileID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedProfileIDs.contains(profileID) },
            set: { selected in
                if selected {
                    selectedProfileIDs.insert(profileID)
                } else {
                    selectedProfileIDs.remove(profileID)
                }
            }
        )
    }
}

private extension SelectiveRemoteCloudTeamRole {
    var localizedTitle: String {
        switch self {
        case .owner: UpdateLocalization.text(ru: "Владелец", en: "Owner")
        case .admin: UpdateLocalization.text(ru: "Администратор", en: "Admin")
        case .editor: UpdateLocalization.text(ru: "Редактор", en: "Editor")
        case .viewer: UpdateLocalization.text(ru: "Просмотр", en: "Viewer")
        }
    }
}
