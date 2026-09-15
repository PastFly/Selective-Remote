import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

struct SelectiveRemoteTeamCredential: Identifiable, Equatable, Sendable {
    let id: UUID
    let recordID: UUID
    let teamID: UUID
    let teamName: String
    let role: SelectiveRemoteCloudTeamRole
    let vaultID: UUID
    let vaultName: String
    let revision: Int
    let keyGeneration: Int
    let modifiedDate: Date
    let title: String
    let username: String
    let secret: String
    let sourceHostID: UUID?
    let sourceHostTitle: String?
    let kind: KeychainCredentialKind?
}

enum SelectiveRemoteTeamCredentialMaterializationError: Error, Equatable {
    case invalidSnapshot
    case invalidCredentialRecord
}

enum SelectiveRemoteTeamCredentialMaterializer {
    private static let credentialKeys = Set(["title", "username", "secret"])
    private static let hostCredentialKeys = Set([
        "title", "username", "secret", "kind", "sourceID"
    ])

    static func materialize(
        _ snapshot: SelectiveRemoteTeamVaultMaterializedSnapshot
    ) throws -> [SelectiveRemoteTeamCredential] {
        guard snapshot.teamID.isSelectiveRemoteCloudUUID,
              snapshot.vaultID.isSelectiveRemoteCloudUUID,
              snapshot.revision > 0,
              snapshot.keyGeneration > 0,
              validName(snapshot.teamName),
              validName(snapshot.vaultName)
        else { throw SelectiveRemoteTeamCredentialMaterializationError.invalidSnapshot }

        let document: SelectiveRemoteVaultDocument
        do {
            document = try SelectiveRemoteVaultDocument.decode(snapshot.payload)
        } catch {
            throw SelectiveRemoteTeamCredentialMaterializationError.invalidSnapshot
        }

        let hostTitles = try Dictionary(uniqueKeysWithValues: document.records.compactMap { record
            -> (UUID, String)? in
            guard record.type == .host, case let .object(data) = record.data,
                  let title = string(data["title"]), validName(title)
            else { return nil }
            return (record.id, title)
        })

        return try document.records.compactMap { record in
            guard record.type == .credential else { return nil }
            guard case let .object(data) = record.data else {
                throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
            }
            let keys = Set(data.keys)
            let sourceHostID: UUID?
            let sourceHostTitle: String?
            let kind: KeychainCredentialKind?
            if keys == hostCredentialKeys {
                guard let sourceText = string(data["sourceID"]),
                      let resolvedSourceID = UUID(uuidString: sourceText),
                      let resolvedHostTitle = hostTitles[resolvedSourceID],
                      let kindText = string(data["kind"]),
                      let resolvedKind = KeychainCredentialKind(rawValue: kindText),
                      resolvedKind != .sshKeyAuthorization
                else {
                    throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
                }
                sourceHostID = resolvedSourceID
                sourceHostTitle = resolvedHostTitle
                kind = resolvedKind
            } else if keys == credentialKeys {
                sourceHostID = nil
                sourceHostTitle = nil
                kind = nil
            } else {
                throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
            }
            guard
                  let title = string(data["title"]),
                  let username = string(data["username"]),
                  let secret = string(data["secret"]),
                  validName(title),
                  validUsername(username),
                  validSecret(secret),
                  let modifiedDate = timestamp(record.modifiedAt)
            else {
                throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
            }
            return .init(
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
                modifiedDate: modifiedDate,
                title: title,
                username: username,
                secret: secret,
                sourceHostID: sourceHostID,
                sourceHostTitle: sourceHostTitle,
                kind: kind
            )
        }
    }

    static func scopedID(teamID: UUID, vaultID: UUID, recordID: UUID) -> UUID {
        let scope = [
            "selective-remote/team-credential/v1",
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

    private static func validUsername(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 2_048
            && !value.contains(where: { $0.isNewline })
    }

    private static func validSecret(_ value: String) -> Bool {
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
final class SelectiveRemoteTeamCredentialStore: ObservableObject {
    static let shared = SelectiveRemoteTeamCredentialStore()

    @Published private(set) var credentials: [SelectiveRemoteTeamCredential] = []
    @Published private(set) var synchronizedVaultCount = 0
    @Published private(set) var invalidVaultCount = 0
    @Published private(set) var lastUpdatedAt: Date?

    func replace(
        with snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot],
        now: Date = Date()
    ) {
        var next: [SelectiveRemoteTeamCredential] = []
        var invalid = 0
        for snapshot in snapshots {
            do {
                next += try SelectiveRemoteTeamCredentialMaterializer.materialize(snapshot)
            } catch {
                invalid += 1
            }
        }
        credentials = next.sorted {
            let left = [$0.teamName, $0.vaultName, $0.title].map(\.localizedLowercase)
            let right = [$1.teamName, $1.vaultName, $1.title].map(\.localizedLowercase)
            return left == right
                ? $0.recordID.canonicalCloudString < $1.recordID.canonicalCloudString
                : left.lexicographicallyPrecedes(right)
        }
        synchronizedVaultCount = snapshots.count - invalid
        invalidVaultCount = invalid
        lastUpdatedAt = snapshots.isEmpty ? nil : now
    }

    func clear() {
        replace(with: [])
    }
}

@MainActor
struct SelectiveRemoteTeamCredentialsView: View {
    @ObservedObject var store: SelectiveRemoteTeamCredentialStore

    @State private var query = ""
    @State private var selectedCredentialID: UUID?
    @State private var selectedVaultKey = ""
    @State private var revealedCredentialIDs: Set<UUID> = []
    @State private var revealTasks: [UUID: Task<Void, Never>] = [:]
    @State private var feedback = ""

    private var visibleCredentials: [SelectiveRemoteTeamCredential] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.credentials.filter { credential in
            (selectedVaultKey.isEmpty || vaultKey(credential) == selectedVaultKey)
                && (normalized.isEmpty || [
                    credential.title, credential.username,
                    credential.teamName, credential.vaultName,
                    credential.sourceHostTitle ?? "", credentialKindTitle(credential.kind)
                ].contains { $0.localizedCaseInsensitiveContains(normalized) })
        }
    }

    private var selectedCredential: SelectiveRemoteTeamCredential? {
        visibleCredentials.first { $0.id == selectedCredentialID }
    }

    var body: some View {
        GeometryReader { proxy in
            HSplitView {
                VStack(spacing: 0) {
                    controls
                    Divider()
                    if store.credentials.isEmpty {
                        ContentUnavailableView(
                            UpdateLocalization.text(
                                ru: "Team Credentials пока не синхронизированы",
                                en: "Team Credentials Have Not Synchronized Yet"
                            ),
                            systemImage: "key.viewfinder",
                            description: Text(UpdateLocalization.text(
                                ru: "Разблокируйте приложение и дождитесь безопасной синхронизации Team Vault.",
                                en: "Unlock the app and wait for secure Team Vault synchronization."
                            ))
                        )
                    } else if visibleCredentials.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        List(visibleCredentials, selection: $selectedCredentialID) { credential in
                            credentialRow(credential)
                                .tag(credential.id)
                                .contextMenu { credentialActions(credential) }
                        }
                        .listStyle(.inset)
                    }
                    Divider()
                    status
                }
                .frame(minWidth: 340, idealWidth: max(400, proxy.size.width * 0.42))

                Group {
                    if let selectedCredential {
                        inspector(selectedCredential)
                    } else {
                        ContentUnavailableView(
                            UpdateLocalization.text(
                                ru: "Выберите Team Credential",
                                en: "Select a Team Credential"
                            ),
                            systemImage: "key.viewfinder"
                        )
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { normalizeSelection() }
        .onChange(of: store.credentials.map(\.id)) { _, _ in normalizeSelection() }
        .onChange(of: selectedVaultKey) { _, _ in normalizeSelection() }
        .onChange(of: selectedCredentialID) { _, _ in feedback = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            concealAll()
        }
        .onDisappear { concealAll() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(
                    UpdateLocalization.text(
                        ru: "Название, логин, имя команды или Vault",
                        en: "Title, username, Team, or Vault"
                    ),
                    text: $query
                )
                .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Menu {
                    Button(UpdateLocalization.text(ru: "Все Team Vaults", en: "All Team Vaults")) {
                        selectedVaultKey = ""
                    }
                    Divider()
                    ForEach(vaultOptions, id: \.key) { option in
                        Button(option.title) { selectedVaultKey = option.key }
                    }
                } label: {
                    Label(selectedVaultTitle, systemImage: "tray.full")
                }
                .menuStyle(.borderlessButton)
                Spacer()
                Text("\(visibleCredentials.count) \(UpdateLocalization.text(ru: "из", en: "of")) \(store.credentials.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func credentialRow(_ credential: SelectiveRemoteTeamCredential) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(credential.title).font(.headline).lineLimit(1)
                Spacer()
                Text(roleTitle(credential.role))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("\(credential.teamName) / \(credential.vaultName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(credential.username)
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            if let sourceHostTitle = credential.sourceHostTitle {
                Label(
                    "\(UpdateLocalization.text(ru: "Хост", en: "Host")): \(sourceHostTitle) · \(credentialKindTitle(credential.kind))",
                    systemImage: "display"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }

    private func inspector(_ credential: SelectiveRemoteTeamCredential) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "key.viewfinder")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(credential.title).font(.title2.bold())
                    Text("\(credential.teamName) / \(credential.vaultName)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copy(credential.secret, message: UpdateLocalization.text(
                        ru: "Пароль скопирован",
                        en: "Password copied"
                    ))
                } label: {
                    Label(UpdateLocalization.text(ru: "Копировать пароль", en: "Copy Password"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 18) {
                Label(roleTitle(credential.role), systemImage: "person.badge.shield.checkmark")
                if let sourceHostTitle = credential.sourceHostTitle {
                    Label(
                        "\(UpdateLocalization.text(ru: "Хост", en: "Host")): \(sourceHostTitle) · \(credentialKindTitle(credential.kind))",
                        systemImage: "display"
                    )
                }
                Label(
                    "r\(credential.revision) · k\(credential.keyGeneration)",
                    systemImage: "lock.shield"
                )
                Label(credential.modifiedDate.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GroupBox(UpdateLocalization.text(ru: "Имя пользователя", en: "Username")) {
                HStack {
                    Text(credential.username).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button(UpdateLocalization.text(ru: "Копировать", en: "Copy"), systemImage: "doc.on.doc") {
                        copy(credential.username, message: UpdateLocalization.text(
                            ru: "Имя пользователя скопировано",
                            en: "Username copied"
                        ))
                    }
                }
                .padding(8)
            }

            GroupBox(UpdateLocalization.text(ru: "Пароль", en: "Password")) {
                HStack {
                    if revealedCredentialIDs.contains(credential.id) {
                        Text(credential.secret)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .privacySensitive()
                    } else {
                        Text(maskedSecret(credential))
                            .font(.body.monospaced())
                    }
                    Spacer()
                    Button {
                        toggleReveal(credential.id)
                    } label: {
                        Label(
                            revealedCredentialIDs.contains(credential.id)
                                ? UpdateLocalization.text(ru: "Скрыть", en: "Hide")
                                : UpdateLocalization.text(ru: "Показать", en: "Reveal"),
                            systemImage: revealedCredentialIDs.contains(credential.id) ? "eye.slash" : "eye"
                        )
                    }
                }
                .padding(8)
            }

            if !feedback.isEmpty {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()
            Label(
                UpdateLocalization.text(
                    ru: "Секрет находится только в памяти после расшифровки Team Vault и открывается или копируется только по вашему действию.",
                    en: "The secret exists only in memory after Team Vault decryption and is revealed or copied only by your action."
                ),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    @ViewBuilder
    private func credentialActions(_ credential: SelectiveRemoteTeamCredential) -> some View {
        Button(UpdateLocalization.text(ru: "Копировать логин", en: "Copy Username"), systemImage: "person.crop.circle") {
            copy(credential.username, message: UpdateLocalization.text(
                ru: "Имя пользователя скопировано",
                en: "Username copied"
            ))
        }
        Button(UpdateLocalization.text(ru: "Копировать пароль", en: "Copy Password"), systemImage: "doc.on.doc") {
            copy(credential.secret, message: UpdateLocalization.text(
                ru: "Пароль скопирован",
                en: "Password copied"
            ))
        }
        Divider()
        Button(
            revealedCredentialIDs.contains(credential.id)
                ? UpdateLocalization.text(ru: "Скрыть пароль", en: "Hide Password")
                : UpdateLocalization.text(ru: "Показать пароль", en: "Reveal Password"),
            systemImage: revealedCredentialIDs.contains(credential.id) ? "eye.slash" : "eye"
        ) {
            toggleReveal(credential.id)
        }
    }

    private var vaultOptions: [(key: String, title: String)] {
        Dictionary(grouping: store.credentials, by: { vaultKey($0) })
            .compactMap { _, values in
                guard let value = values.first else { return nil }
                return (vaultKey(value), "\(value.teamName) / \(value.vaultName)")
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var selectedVaultTitle: String {
        vaultOptions.first { $0.key == selectedVaultKey }?.title
            ?? UpdateLocalization.text(ru: "Все Team Vaults", en: "All Team Vaults")
    }

    private func vaultKey(_ credential: SelectiveRemoteTeamCredential) -> String {
        "\(credential.teamID.canonicalCloudString)/\(credential.vaultID.canonicalCloudString)"
    }

    private func normalizeSelection() {
        if !selectedVaultKey.isEmpty && !vaultOptions.contains(where: { $0.key == selectedVaultKey }) {
            selectedVaultKey = ""
        }
        if selectedCredential == nil { selectedCredentialID = visibleCredentials.first?.id }
    }

    private func toggleReveal(_ id: UUID) {
        if revealedCredentialIDs.contains(id) {
            conceal(id)
        } else {
            revealedCredentialIDs.insert(id)
            revealTasks[id]?.cancel()
            revealTasks[id] = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: CredentialDisclosurePolicy.visibleNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                conceal(id)
            }
        }
    }

    private func conceal(_ id: UUID) {
        revealTasks[id]?.cancel()
        revealTasks[id] = nil
        revealedCredentialIDs.remove(id)
    }

    private func concealAll() {
        for task in revealTasks.values { task.cancel() }
        revealTasks.removeAll()
        revealedCredentialIDs.removeAll()
    }

    private func maskedSecret(_ credential: SelectiveRemoteTeamCredential) -> String {
        guard !revealedCredentialIDs.contains(credential.id) else { return credential.secret }
        return String(repeating: "•", count: min(max(credential.secret.count, 8), 24))
    }

    private func copy(_ value: String, message: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else { return }
        feedback = message
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: CredentialDisclosurePolicy.clipboardNanoseconds
            )
            if NSPasteboard.general.string(forType: .string) == value {
                NSPasteboard.general.clearContents()
            }
        }
    }

    private func roleTitle(_ role: SelectiveRemoteCloudTeamRole) -> String {
        switch role {
        case .owner: UpdateLocalization.text(ru: "Владелец", en: "Owner")
        case .admin: UpdateLocalization.text(ru: "Администратор", en: "Admin")
        case .editor: UpdateLocalization.text(ru: "Редактор", en: "Editor")
        case .viewer: UpdateLocalization.text(ru: "Просмотр", en: "Viewer")
        }
    }

    private func credentialKindTitle(_ kind: KeychainCredentialKind?) -> String {
        switch kind {
        case .rdp: "RDP"
        case .gateway: UpdateLocalization.text(ru: "Шлюз", en: "Gateway")
        case .ssh: "SSH"
        case .forwarding: "Forwarding"
        case .proxy: "Proxy"
        case .sshKeyAuthorization: "SSH Key"
        case nil: UpdateLocalization.text(ru: "Самостоятельная", en: "Standalone")
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if let lastUpdatedAt = store.lastUpdatedAt {
                Label(lastUpdatedAt.formatted(date: .omitted, time: .shortened), systemImage: "arrow.triangle.2.circlepath")
            }
            Text(UpdateLocalization.text(
                ru: "Team Vaults: \(store.synchronizedVaultCount)",
                en: "Team Vaults: \(store.synchronizedVaultCount)"
            ))
            if store.invalidVaultCount > 0 {
                Label("\(store.invalidVaultCount)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(UpdateLocalization.text(ru: "Только в памяти", en: "Memory only"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
    }
}
