import SwiftUI

private struct ForwardConnectionRequest: Identifiable {
    let id = UUID()
    let tunnelID: UUID
    let connection: TerminalTabConnection
}

struct IndependentForwardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var connectionRequest: ForwardConnectionRequest?
    @State private var passwordInputs: [UUID: String] = [:]

    private var sshProfiles: [ConnectionProfile] {
        model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName)
                    == .orderedAscending
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Forwarding")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(
                            "Независимые SSH-туннели работают отдельно от карточек подключений."
                        )
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Добавить туннель", systemImage: "plus") {
                        ForEach(PortForwardKind.allCases) { kind in
                            Button {
                                model.addIndependentPortForward(kind)
                            } label: {
                                Label {
                                    Text(LocalizedStringKey(kind.title))
                                } icon: {
                                    Image(systemName: kind.systemImage)
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if model.independentPortForwards.isEmpty {
                    ContentUnavailableView(
                        "Туннелей пока нет",
                        systemImage: "arrow.left.arrow.right",
                        description: Text(
                            "Создайте локальный, удалённый или SOCKS-туннель и выберите для него SSH-сервер."
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                } else {
                    ForEach(model.independentPortForwards) { item in
                        tunnelCard(item)
                    }
                }

                GroupBox("Подсказка") {
                    Text(
                        "Сохранённый профиль использует свой SSH-ключ и настройки безопасности. "
                            + "Для ручного адреса фоновой процесс использует системный ssh-agent "
                            + "и ~/.ssh/config; интерактивный пароль для туннелей не поддерживается."
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .padding(8)
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $connectionRequest) { request in
            TerminalConnectionEditor(
                profiles: sshProfiles,
                initialConnection: request.connection,
                allowsInteractivePassword: false,
                actionTitle: "Сохранить",
                customAuthenticationMessage: "Для ручного SSH-сервера пароль можно сохранить в Keychain прямо в карточке туннеля.",
                onSave: { connection, _ in
                    guard var item = model.independentPortForwards.first(where: {
                        $0.id == request.tunnelID
                    }) else { return }
                    item.connection = connection
                    model.updateIndependentPortForward(item)
                }
            )
        }
    }

    private func tunnelCard(_ item: IndependentPortForward) -> some View {
        let running = model.isSSHTunnelRunning(ruleID: item.id)
        let binding = binding(for: item.id)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: item.rule.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                TextField("Название правила", text: binding.rule.name)
                    .font(.headline)
                    .textFieldStyle(.roundedBorder)
                    .disabled(running)
                Button {
                    connectionRequest = ForwardConnectionRequest(
                        tunnelID: item.id,
                        connection: item.connection
                    )
                } label: {
                    Label(
                        item.connection.displayLabel(profiles: sshProfiles),
                        systemImage: "server.rack"
                    )
                }
                .disabled(running)
                .help("Выбрать SSH-сервер для туннеля")

                if running {
                    Button("Остановить", systemImage: "stop.fill", role: .destructive) {
                        model.stopSSHTunnel(item.id)
                    }
                } else {
                    Button("Запустить", systemImage: "play.fill") {
                        model.startIndependentPortForward(item.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    model.revealSSHTunnelLog(item.id)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Показать журнал туннеля")
                Button(role: .destructive) {
                    model.removeIndependentPortForward(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(running)
            }

            if item.connection.kind == .custom {
                HStack(spacing: 10) {
                    Label("SSH-пароль", systemImage: "key.fill")
                        .frame(width: 120, alignment: .leading)
                    SecureField(
                        model.hasSavedForwardingPassword(item.id)
                            ? "Сохранён в Keychain — введите новый для замены"
                            : "Пароль SSH-сервера",
                        text: passwordBinding(for: item.id)
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(running)
                    Button("Сохранить") {
                        let value = passwordInputs[item.id] ?? ""
                        guard !value.isEmpty else { return }
                        model.saveForwardingPassword(value, tunnelID: item.id)
                        passwordInputs[item.id] = ""
                    }
                    .disabled(running || (passwordInputs[item.id] ?? "").isEmpty)
                    if model.hasSavedForwardingPassword(item.id) {
                        Button("Удалить", role: .destructive) {
                            model.deleteSavedForwardingPassword(item.id)
                            passwordInputs[item.id] = ""
                        }
                        .disabled(running)
                    }
                }
                Text("Пароль хранится только в macOS Keychain и не записывается в настройки туннеля.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("SSH-аутентификация берётся из выбранного сохранённого профиля.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Режим", selection: binding.rule.kind) {
                ForEach(PortForwardKind.allCases) { kind in
                    Label {
                        Text(LocalizedStringKey(kind.title))
                    } icon: {
                        Image(systemName: kind.systemImage)
                    }
                    .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(running)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(item.rule.kind == .remote ? "Слушать на сервере" : "Слушать на Mac")
                    TextField("127.0.0.1", text: binding.rule.bindAddress)
                        .textFieldStyle(.roundedBorder)
                        .disabled(running)
                    Text("Порт")
                    TextField("8080", value: binding.rule.sourcePort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 105)
                        .disabled(running)
                }
                if item.rule.kind != .dynamic {
                    GridRow {
                        Text("Назначение")
                        TextField("127.0.0.1", text: binding.rule.destinationHost)
                            .textFieldStyle(.roundedBorder)
                            .disabled(running)
                        Text("Порт")
                        TextField("80", value: binding.rule.destinationPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 105)
                            .disabled(running)
                    }
                }
            }
        }
        .padding(18)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    running ? Color.green.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: running ? 2 : 1
                )
        }
    }

    private func passwordBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { passwordInputs[id] ?? "" },
            set: { passwordInputs[id] = $0 }
        )
    }

    private func binding(for id: UUID) -> Binding<IndependentPortForward> {
        Binding(
            get: {
                model.independentPortForwards.first(where: { $0.id == id })
                    ?? IndependentPortForward(
                        id: id,
                        connection: .custom(host: "", username: "")
                    )
            },
            set: { model.updateIndependentPortForward($0) }
        )
    }
}
