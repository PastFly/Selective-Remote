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

struct SelectiveRemoteTeamSnippetsView: View {
    @ObservedObject var store: SelectiveRemoteTeamSnippetStore

    @State private var query = ""
    @State private var selectedSnippetID: UUID?
    @State private var selectedVaultKey = ""
    @State private var copiedSnippetID: UUID?

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
                Label {
                    Text(snippet.modifiedDate, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
                Label("r\(snippet.revision) · k\(snippet.keyGeneration)", systemImage: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

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
                    ru: "Команда показывается только в памяти после расшифровки Team Vault. Она не запускается автоматически; копирование выполняется только по вашему нажатию.",
                    en: "The command exists only in memory after Team Vault decryption. It never runs automatically; copying requires your explicit action."
                ),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
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
