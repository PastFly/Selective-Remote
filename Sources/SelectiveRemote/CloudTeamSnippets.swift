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
}

struct SelectiveRemoteTeamSnippetVaultContext: Identifiable, Equatable, Sendable {
    let id: UUID
    let teamID: UUID
    let teamName: String
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
            guard case let .object(data) = record.data,
                  Set(data.keys) == Set(["title", "body"]),
                  let title = string(data["title"]),
                  let body = string(data["body"]),
                  validTitle(title),
                  validBody(body),
                  let modifiedDate = timestamp(record.modifiedAt)
            else { throw SelectiveRemoteTeamSnippetMaterializationError.invalidSnippetRecord }

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
                body: body
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

    @State private var query = ""
    @State private var selectedSnippetID: UUID?
    @State private var selectedVaultKey = ""
    @State private var copiedSnippetID: UUID?
    @State private var targetEditorSnippet: SelectiveRemoteTeamSnippet?
    @State private var actionMessage = ""

    init(
        store: SelectiveRemoteTeamSnippetStore,
        model: AppModel,
        targetStore: SelectiveRemoteTeamSnippetTargetStore = .shared
    ) {
        self.store = store
        self.model = model
        self.targetStore = targetStore
    }

    private var visibleSnippets: [SelectiveRemoteTeamSnippet] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.snippets.filter { snippet in
            (selectedVaultKey.isEmpty || vaultKey(snippet) == selectedVaultKey)
                && (normalizedQuery.isEmpty || [
                    snippet.title, snippet.body, snippet.teamName, snippet.vaultName
                ].contains { $0.localizedCaseInsensitiveContains(normalizedQuery) })
        }
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
                        List(visibleSnippets, selection: $selectedSnippetID) { snippet in
                            snippetRow(snippet)
                                .tag(snippet.id)
                                .contextMenu { snippetActions(snippet) }
                        }
                        .listStyle(.inset)
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
        .onChange(of: selectedSnippetID) { _, _ in actionMessage = "" }
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
                Spacer()
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
            Text("\(snippet.teamName) / \(snippet.vaultName)")
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
                    Text("\(snippet.teamName) / \(snippet.vaultName)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
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

    private func vaultKey(_ snippet: SelectiveRemoteTeamSnippet) -> String {
        "\(snippet.teamID.canonicalCloudString)/\(snippet.vaultID.canonicalCloudString)"
    }

    private func normalizeSelection() {
        if !selectedVaultKey.isEmpty,
           !store.vaults.contains(where: { $0.selectionKey == selectedVaultKey }) {
            selectedVaultKey = ""
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
            category: "\(snippet.teamName) / \(snippet.vaultName)",
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
            return UpdateLocalization.text(
                ru: "Изменён \(minutes) \(russianUnit(minutes, one: \"минуту\", few: \"минуты\", many: \"минут\")) назад",
                en: "Modified \(minutes) \(minutes == 1 ? \"minute\" : \"minutes\") ago"
            )
        }
        if elapsed < 86_400 {
            let hours = max(1, elapsed / 3_600)
            return UpdateLocalization.text(
                ru: "Изменён \(hours) \(russianUnit(hours, one: \"час\", few: \"часа\", many: \"часов\")) назад",
                en: "Modified \(hours) \(hours == 1 ? \"hour\" : \"hours\") ago"
            )
        }
        let days = max(1, elapsed / 86_400)
        return UpdateLocalization.text(
            ru: "Изменён \(days) \(russianUnit(days, one: \"день\", few: \"дня\", many: \"дней\")) назад",
            en: "Modified \(days) \(days == 1 ? \"day\" : \"days\") ago"
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
