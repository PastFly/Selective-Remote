import SwiftUI

struct SelectiveRemoteTeamHostEditorRequest: Identifiable {
    let id = UUID()
    let context: SelectiveRemoteTeamHostVaultContext
    let host: SelectiveRemoteTeamHost?
}

struct SelectiveRemoteTeamHostMutationMessage: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct SelectiveRemoteTeamHostEditorView: View {
    let request: SelectiveRemoteTeamHostEditorRequest
    let onSave: (ConnectionProfile, SelectiveRemoteTeamHostCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var address: String
    @State private var username: String
    @State private var port: Int
    @State private var connectionType: ConnectionType
    @State private var folder: String
    @State private var tagsText: String
    @State private var profileDescription: String
    @State private var password: String
    @State private var gatewayPassword: String

    init(
        request: SelectiveRemoteTeamHostEditorRequest,
        onSave: @escaping (ConnectionProfile, SelectiveRemoteTeamHostCredentials) -> Void
    ) {
        self.request = request
        self.onSave = onSave
        let profile = request.host?.profile
        _title = State(initialValue: profile?.friendlyName ?? "")
        _address = State(initialValue: profile.map(Self.address) ?? "")
        _username = State(initialValue: profile?.username ?? "")
        _port = State(initialValue: profile?.sshPort ?? 22)
        _connectionType = State(initialValue: profile?.connectionType ?? .ssh)
        _folder = State(initialValue: profile?.group ?? "")
        _tagsText = State(initialValue: profile?.tags.joined(separator: ", ") ?? "")
        _profileDescription = State(initialValue: profile?.profileDescription ?? "")
        _password = State(initialValue: request.host?.credentials.password ?? "")
        _gatewayPassword = State(initialValue: request.host?.credentials.gatewayPassword ?? "")
    }

    private var isValid: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanTitle.isEmpty
            && cleanTitle == title
            && title.count <= 120
            && !title.contains(where: { $0.isNewline })
            && !cleanAddress.isEmpty
            && cleanAddress == address
            && address.utf8.count <= 2_048
            && !address.contains(where: { $0.isNewline })
            && username.count <= 256
            && !username.contains(where: { $0.isNewline })
            && ((connectionType != .ssh && connectionType != .telnet) || (1 ... 65_535).contains(port))
            && validFolder
            && tagsText.utf8.count <= 8_192
            && parsedTags.count <= 64
            && Set(parsedTags).count == parsedTags.count
            && parsedTags.allSatisfy { $0.count <= 64 && !$0.contains(where: { $0.isNewline }) }
            && profileDescription.utf8.count <= 2_048
            && !profileDescription.contains(where: { $0.isNewline })
            && (connectionType != .serial || address.hasPrefix("/dev/cu."))
    }

    private var parsedTags: [String] {
        tagsText.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var validFolder: Bool {
        folder.isEmpty || (
            folder == folder.trimmingCharacters(in: .whitespacesAndNewlines)
                && folder.count <= 120
                && !folder.contains(where: { $0.isNewline })
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.host == nil
                    ? UpdateLocalization.text(ru: "Новый Team Host", en: "New Team Host")
                    : UpdateLocalization.text(ru: "Изменить Team Host", en: "Edit Team Host")
                )
                .font(.title2.bold())
                Text("\(request.context.teamName) / \(request.context.vaultName)")
                    .foregroundStyle(.secondary)
            }

            Form {
                LabeledContent(
                    UpdateLocalization.text(ru: "Роль", en: "Role"),
                    value: Self.roleTitle(request.context.role)
                )
                Picker(
                    UpdateLocalization.text(ru: "Протокол", en: "Protocol"),
                    selection: $connectionType
                ) {
                    Text("RDP").tag(ConnectionType.rdp)
                    Text("SSH").tag(ConnectionType.ssh)
                    Text("Telnet").tag(ConnectionType.telnet)
                    Text("Serial").tag(ConnectionType.serial)
                }
                .disabled(request.host != nil)
                .help(request.host == nil
                    ? ""
                    : UpdateLocalization.text(
                        ru: "Протокол существующего Team Host нельзя менять в этой форме",
                        en: "This form does not change an existing Team Host protocol"
                    )
                )

                TextField(
                    UpdateLocalization.text(ru: "Название", en: "Name"),
                    text: $title
                )
                TextField(
                    connectionType == .serial
                        ? UpdateLocalization.text(ru: "Устройство", en: "Device")
                        : UpdateLocalization.text(ru: "Host или IP", en: "Host or IP"),
                    text: $address
                )
                if connectionType == .rdp || connectionType == .ssh {
                    TextField(
                        UpdateLocalization.text(ru: "Пользователь", en: "Username"),
                        text: $username
                    )
                }
                if connectionType == .ssh || connectionType == .telnet {
                    TextField(
                        UpdateLocalization.text(ru: "Порт", en: "Port"),
                        value: $port,
                        format: .number
                    )
                }
                if connectionType == .rdp || connectionType == .ssh {
                    SecureField(
                        UpdateLocalization.text(
                            ru: "Общий пароль (Team Vault)",
                            en: "Shared Password (Team Vault)"
                        ),
                        text: $password
                    )
                }
                if connectionType == .rdp {
                    SecureField(
                        UpdateLocalization.text(
                            ru: "Общий пароль Gateway (Team Vault)",
                            en: "Shared Gateway Password (Team Vault)"
                        ),
                        text: $gatewayPassword
                    )
                }
                TextField(
                    UpdateLocalization.text(ru: "Папка", en: "Folder"),
                    text: $folder
                )
                TextField(
                    UpdateLocalization.text(
                        ru: "Теги через запятую",
                        en: "Comma-separated tags"
                    ),
                    text: $tagsText
                )
                TextField(
                    UpdateLocalization.text(ru: "Описание", en: "Description"),
                    text: $profileDescription,
                    axis: .vertical
                )
                .lineLimit(2 ... 5)
            }
            .formStyle(.grouped)

            Label(
                UpdateLocalization.text(
                    ru: "Общие пароли шифруются внутри Team Vault. Пустое поле удаляет общий пароль; ссылки на Personal Vault не сохраняются.",
                    en: "Shared passwords are encrypted inside Team Vault. An empty field removes the shared password; Personal Vault references are never saved."
                ),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel")) {
                    dismiss()
                }
                Button(request.host == nil
                    ? UpdateLocalization.text(ru: "Добавить", en: "Add")
                    : UpdateLocalization.text(ru: "Сохранить", en: "Save")
                ) {
                    onSave(
                        profile(),
                        .init(
                            password: password.isEmpty ? nil : password,
                            gatewayPassword: gatewayPassword.isEmpty ? nil : gatewayPassword
                        )
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func profile() -> ConnectionProfile {
        var profile = request.host?.profile ?? ConnectionProfile(connectionType: connectionType)
        profile.id = request.host?.recordID ?? UUID()
        profile.friendlyName = title
        profile.username = username
        profile.group = folder
        profile.tags = parsedTags
        profile.profileDescription = profileDescription
        if connectionType == .ssh || connectionType == .telnet {
            profile.sshPort = port
        }
        if connectionType == .serial {
            profile.serialDevicePath = address
        } else {
            profile.host = address
        }
        return profile
    }

    private static func address(_ profile: ConnectionProfile) -> String {
        profile.connectionType == .serial ? profile.serialDevicePath : profile.host
    }

    private static func roleTitle(_ role: SelectiveRemoteCloudTeamRole) -> String {
        switch role {
        case .owner: "Owner"
        case .admin: "Admin"
        case .editor: "Editor"
        case .viewer: "Viewer"
        }
    }
}
