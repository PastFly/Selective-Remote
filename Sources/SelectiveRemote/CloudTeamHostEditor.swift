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
    let onSave: (ConnectionProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var address: String
    @State private var username: String
    @State private var connectionType: ConnectionType

    init(
        request: SelectiveRemoteTeamHostEditorRequest,
        onSave: @escaping (ConnectionProfile) -> Void
    ) {
        self.request = request
        self.onSave = onSave
        let profile = request.host?.profile
        _title = State(initialValue: profile?.friendlyName ?? "")
        _address = State(initialValue: profile.map(Self.address) ?? "")
        _username = State(initialValue: profile?.username ?? "")
        _connectionType = State(initialValue: profile?.connectionType ?? .ssh)
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
            && (connectionType != .serial || address.hasPrefix("/dev/cu."))
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
            }
            .formStyle(.grouped)

            Label(
                UpdateLocalization.text(
                    ru: "Пароли и ссылки на Personal Vault не сохраняются в Team Host.",
                    en: "Passwords and Personal Vault references are not saved in a Team Host."
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
                    onSave(profile())
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
