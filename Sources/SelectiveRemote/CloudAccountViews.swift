import SwiftUI

struct SelectiveRemoteCloudSignInView: View {
    let endpoint: URL
    let registrationEnabled: Bool?
    let isSigningIn: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onCreateAccount: () -> Void
    let onSignIn: (String, String) -> Void

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(UpdateLocalization.text(ru: "Электронная почта", en: "Email"), text: $email)
                        .textContentType(.username)
                        .disabled(isSigningIn)
                    SecureField(UpdateLocalization.text(ru: "Пароль", en: "Password"), text: $password)
                        .textContentType(.password)
                        .disabled(isSigningIn)
                        .onSubmit(submit)
                }

                Section {
                    LabeledContent(UpdateLocalization.text(ru: "Сервер", en: "Server")) {
                        Text(endpoint.host ?? endpoint.absoluteString)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Label(
                        UpdateLocalization.text(
                            ru: "Сессия хранится в Keychain только на этом Mac. Пароль существует только в этой форме и не становится ключом Vault.",
                            en: "The session is stored in Keychain on this Mac only. The password exists only in this form and never becomes a Vault key."
                        ),
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    if registrationEnabled == true {
                        Button(
                            UpdateLocalization.text(ru: "Создать новый аккаунт…", en: "Create New Account…"),
                            systemImage: "person.crop.circle.badge.plus",
                            action: onCreateAccount
                        )
                        .disabled(isSigningIn)
                    } else if registrationEnabled == false {
                        Label(
                            UpdateLocalization.text(
                                ru: "Регистрация на этом сервере пока отключена. Для входа нужен уже созданный и подтверждённый аккаунт.",
                                en: "Registration is currently disabled on this server. Sign-in requires an existing verified account."
                            ),
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            UpdateLocalization.text(
                                ru: "Сначала проверьте соединение, чтобы узнать, разрешена ли регистрация.",
                                en: "Check the connection first to learn whether registration is available."
                            ),
                            systemImage: "network"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(UpdateLocalization.text(ru: "Вход в Cloud", en: "Cloud Sign In"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), action: onCancel)
                        .disabled(isSigningIn)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(UpdateLocalization.text(ru: "Войти", en: "Sign In"), action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit || isSigningIn)
                }
            }
        }
        .frame(width: 500, height: 390)
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (12...1_024).contains(password.count)
    }

    private func submit() {
        guard canSubmit, !isSigningIn else { return }
        onSignIn(email, password)
    }
}

struct SelectiveRemoteCloudRegistrationView: View {
    let endpoint: URL
    let isRegistering: Bool
    let errorMessage: String?
    let onBack: () -> Void
    let onCancel: () -> Void
    let onRegister: (String, String, String) -> Void

    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(UpdateLocalization.text(ru: "Имя", en: "Display Name"), text: $displayName)
                        .textContentType(.name)
                        .disabled(isRegistering)
                    TextField(UpdateLocalization.text(ru: "Электронная почта", en: "Email"), text: $email)
                        .textContentType(.emailAddress)
                        .disabled(isRegistering)
                    SecureField(UpdateLocalization.text(ru: "Новый пароль", en: "New Password"), text: $password)
                        .textContentType(.newPassword)
                        .disabled(isRegistering)
                    SecureField(UpdateLocalization.text(ru: "Повторите пароль", en: "Confirm Password"), text: $confirmation)
                        .textContentType(.newPassword)
                        .disabled(isRegistering)
                        .onSubmit(submit)
                }

                Section {
                    LabeledContent(UpdateLocalization.text(ru: "Сервер", en: "Server")) {
                        Text(endpoint.host ?? endpoint.absoluteString)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Label(
                        UpdateLocalization.text(
                            ru: "Используйте свою доступную почту и придумайте новый пароль минимум из 12 символов. После регистрации откройте письмо и подтвердите адрес.",
                            en: "Use an email address you can access and create a new password of at least 12 characters. Then open the message and verify the address."
                        ),
                        systemImage: "envelope.badge.shield.half.filled"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !confirmation.isEmpty, password != confirmation {
                    Section {
                        Label(
                            UpdateLocalization.text(ru: "Пароли не совпадают.", en: "Passwords do not match."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(UpdateLocalization.text(ru: "Регистрация в Cloud", en: "Create Cloud Account"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(UpdateLocalization.text(ru: "Назад", en: "Back"), action: onBack)
                        .disabled(isRegistering)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(UpdateLocalization.text(ru: "Зарегистрироваться", en: "Register"), action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit || isRegistering)
                }
                ToolbarItem(placement: .automatic) {
                    Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), action: onCancel)
                        .disabled(isRegistering)
                }
            }
        }
        .frame(width: 540, height: 520)
    }

    private var canSubmit: Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 120
            && !mail.isEmpty && mail.count <= 254
            && (12...1_024).contains(password.count)
            && password == confirmation
    }

    private func submit() {
        guard canSubmit, !isRegistering else { return }
        onRegister(displayName, email, password)
    }
}

struct SelectiveRemoteCloudRegistrationConfirmationView: View {
    let email: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    UpdateLocalization.text(ru: "Подтвердите почту", en: "Verify Your Email"),
                    systemImage: "envelope.badge"
                )
            } description: {
                Text(UpdateLocalization.text(
                    ru: "Мы отправили одноразовую ссылку на \(email). Откройте её, затем вернитесь в приложение и войдите с созданным паролем.",
                    en: "We sent a one-time link to \(email). Open it, then return to the app and sign in with the password you created."
                ))
            } actions: {
                Button(UpdateLocalization.text(ru: "Готово", en: "Done"), action: onDone)
                    .buttonStyle(.borderedProminent)
            }
            .padding(36)
            .navigationTitle(UpdateLocalization.text(ru: "Аккаунт создан", en: "Account Created"))
        }
        .frame(width: 540, height: 360)
    }
}

struct SelectiveRemoteCloudTeamInventoryView: View {
    let teams: [SelectiveRemoteCloudTeam]
    let vaultsByTeam: [UUID: [SelectiveRemoteCloudSharedVault]]
    let isRefreshing: Bool
    let errorMessage: String?
    let onRefresh: () -> Void

    var body: some View {
        Section(UpdateLocalization.text(ru: "Teams и общие Vaults", en: "Teams & Shared Vaults")) {
            HStack {
                Text(UpdateLocalization.text(
                    ru: "Доступно команд: \(teams.count)",
                    en: "Available teams: \(teams.count)"
                ))
                .foregroundStyle(.secondary)
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button(UpdateLocalization.text(ru: "Обновить", en: "Refresh"), systemImage: "arrow.clockwise") {
                    onRefresh()
                }
                .disabled(isRefreshing)
            }

            if teams.isEmpty, errorMessage == nil, !isRefreshing {
                Label(
                    UpdateLocalization.text(ru: "Команды пока не назначены.", en: "No teams are assigned yet."),
                    systemImage: "person.3"
                )
                .foregroundStyle(.secondary)
            }

            ForEach(teams) { team in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(team.name, systemImage: "person.3.fill")
                            .font(.headline)
                        Spacer()
                        Text(roleTitle(team.role))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }

                    let vaults = vaultsByTeam[team.id] ?? []
                    if vaults.isEmpty {
                        Text(UpdateLocalization.text(ru: "Нет общих Vaults", en: "No shared Vaults"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vaults) { vault in
                            HStack(alignment: .firstTextBaseline) {
                                Label(vault.name, systemImage: "lock.square.stack.fill")
                                Spacer()
                                Text("r\(vault.revision) · k\(vault.keyGeneration)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if vault.rotationRequired {
                                    Label(
                                        UpdateLocalization.text(ru: "Нужна ротация", en: "Rotation required"),
                                        systemImage: "arrow.triangle.2.circlepath"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                }
                            }
                            .padding(.leading, 8)
                        }
                    }
                }
                .padding(.vertical, 5)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func roleTitle(_ role: SelectiveRemoteCloudTeamRole) -> String {
        switch role {
        case .owner: UpdateLocalization.text(ru: "Владелец", en: "Owner")
        case .admin: UpdateLocalization.text(ru: "Администратор", en: "Admin")
        case .editor: UpdateLocalization.text(ru: "Редактор", en: "Editor")
        case .viewer: UpdateLocalization.text(ru: "Читатель", en: "Viewer")
        }
    }
}
