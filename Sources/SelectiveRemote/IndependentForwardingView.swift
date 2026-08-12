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
    @State private var selectedTunnelID: UUID?
    @State private var diagramPulse = false

    private var sshProfiles: [ConnectionProfile] {
        model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending
            }
    }

    private var selectedTunnel: IndependentPortForward? {
        guard let selectedTunnelID else { return model.independentPortForwards.first }
        return model.independentPortForwards.first(where: { $0.id == selectedTunnelID })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.independentPortForwards.isEmpty {
                ContentUnavailableView(
                    "Туннелей пока нет",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Создайте Local, Remote или Dynamic/SOCKS-туннель и выберите SSH-сервер.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    tunnelList
                        .frame(minWidth: 330, idealWidth: 410, maxWidth: 520)

                    if let item = selectedTunnel {
                        tunnelInspector(item)
                            .frame(minWidth: 560)
                    } else {
                        ContentUnavailableView("Выберите туннель", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onAppear {
            if selectedTunnelID == nil {
                selectedTunnelID = model.independentPortForwards.first?.id
            }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                diagramPulse = true
            }
        }
        .onChange(of: model.independentPortForwards) { _, tunnels in
            if let selectedTunnelID,
               !tunnels.contains(where: { $0.id == selectedTunnelID }) {
                self.selectedTunnelID = tunnels.first?.id
            } else if self.selectedTunnelID == nil {
                self.selectedTunnelID = tunnels.first?.id
            }
        }
        .sheet(item: $connectionRequest) { request in
            TerminalConnectionEditor(
                profiles: sshProfiles,
                initialConnection: request.connection,
                allowsInteractivePassword: false,
                allowsTemporaryPassword: false,
                actionTitle: "Сохранить",
                customAuthenticationMessage: "Для ручного SSH-сервера пароль можно сохранить в Keychain прямо в инспекторе туннеля.",
                onSave: { connection, _, _ in
                    guard var item = model.independentPortForwards.first(where: {
                        $0.id == request.tunnelID
                    }) else { return }
                    item.connection = connection
                    model.updateIndependentPortForward(item)
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.13))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Forwarding")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Независимые SSH-туннели · визуальная схема Local / Remote / Dynamic")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var addTunnelMenu: some View {
        Menu {
            ForEach(PortForwardKind.allCases) { kind in
                Button {
                    model.addIndependentPortForward(kind)
                    selectedTunnelID = model.independentPortForwards.last?.id
                } label: {
                    Label {
                        Text(LocalizedStringKey(kind.title))
                    } icon: {
                        Image(systemName: kind.systemImage)
                    }
                }
            }
        } label: {
            Label("Новый туннель", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
    }

    private var tunnelList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                addTunnelMenu
                Spacer()
                Text("\(model.independentPortForwards.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            List(selection: $selectedTunnelID) {
                ForEach(model.independentPortForwards) { item in
                    tunnelRow(item)
                        .tag(item.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu {
                Menu("Новый туннель", systemImage: "plus") {
                    ForEach(PortForwardKind.allCases) { kind in
                        Button(kind.title) {
                            model.addIndependentPortForward(kind)
                            selectedTunnelID = model.independentPortForwards.last?.id
                        }
                    }
                }
            }

            Divider()
            HStack {
                Label("Туннели работают независимо от Terminal/SFTP", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }

    private func tunnelRow(_ item: IndependentPortForward) -> some View {
        let running = model.isSSHTunnelRunning(ruleID: item.id)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Text(shortKind(item.rule.kind))
                    .font(.headline.monospaced())
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.rule.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if running {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                    }
                }
                Text(tunnelSummary(item))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectedTunnelID = item.id
            if !running {
                model.startIndependentPortForward(item.id)
            }
        }
        .contextMenu {
            if running {
                Button("Остановить", systemImage: "stop.fill", role: .destructive) {
                    model.stopSSHTunnel(item.id)
                }
                Button("Перезапустить", systemImage: "arrow.clockwise") {
                    model.restartIndependentPortForward(item.id)
                }
            } else {
                Button("Запустить", systemImage: "play.fill") {
                    model.startIndependentPortForward(item.id)
                }
            }
            Button("Показать журнал", systemImage: "doc.text.magnifyingglass") {
                model.revealSSHTunnelLog(item.id)
            }
            Divider()
            Button("Создать копию", systemImage: "doc.on.doc") {
                selectedTunnelID = model.duplicateIndependentPortForward(item.id)
            }
            Menu("Новый туннель", systemImage: "plus") {
                ForEach(PortForwardKind.allCases) { kind in
                    Button(kind.title) {
                        model.addIndependentPortForward(kind)
                        selectedTunnelID = model.independentPortForwards.last?.id
                    }
                }
            }
            Divider()
            Button("Удалить", systemImage: "trash", role: .destructive) {
                model.removeIndependentPortForward(item.id)
            }
            .disabled(running)
        }
    }

    private func tunnelInspector(_ item: IndependentPortForward) -> some View {
        let running = model.isSSHTunnelRunning(ruleID: item.id)
        let binding = binding(for: item.id)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Название туннеля", text: binding.rule.name)
                            .textFieldStyle(.plain)
                            .font(.title2.bold())
                            .disabled(running)
                        HStack(spacing: 7) {
                            Label(item.rule.kind.title, systemImage: item.rule.kind.systemImage)
                            Text("·")
                            Text(item.connection.displayLabel(profiles: sshProfiles))
                            if running {
                                Text("·")
                                Label("Работает", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
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
                    Menu {
                        Button("Показать журнал", systemImage: "doc.text.magnifyingglass") {
                            model.revealSSHTunnelLog(item.id)
                        }
                        Divider()
                        Button("Удалить туннель", systemImage: "trash", role: .destructive) {
                            model.removeIndependentPortForward(item.id)
                        }
                        .disabled(running)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                forwardingDiagram(item, running: running)

                inspectorCard("Режим", systemImage: "arrow.triangle.branch") {
                    Picker("Режим", selection: binding.rule.kind) {
                        Text("Local").tag(PortForwardKind.local)
                        Text("Remote").tag(PortForwardKind.remote)
                        Text("Dynamic").tag(PortForwardKind.dynamic)
                    }
                    .pickerStyle(.segmented)
                    .disabled(running)

                    Text(modeExplanation(item.rule.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                inspectorCard("SSH-сервер", systemImage: "server.rack") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.connection.displayLabel(profiles: sshProfiles))
                                .font(.headline)
                            Text("Через это SSH-подключение строится туннель")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Выбрать…") {
                            connectionRequest = ForwardConnectionRequest(
                                tunnelID: item.id,
                                connection: item.connection
                            )
                        }
                        .disabled(running)
                    }
                }

                inspectorCard("Маршрут", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text(item.rule.kind == .remote ? "Слушать на сервере" : "Слушать на Mac")
                                .foregroundStyle(.secondary)
                            TextField("127.0.0.1", text: binding.rule.bindAddress)
                                .textFieldStyle(.roundedBorder)
                                .disabled(running)
                            Text("Порт").foregroundStyle(.secondary)
                            TextField("8080", value: binding.rule.sourcePort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .disabled(running)
                        }
                        if item.rule.kind != .dynamic {
                            GridRow {
                                Text("Назначение").foregroundStyle(.secondary)
                                TextField("127.0.0.1", text: binding.rule.destinationHost)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(running)
                                Text("Порт").foregroundStyle(.secondary)
                                TextField("80", value: binding.rule.destinationPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                    .disabled(running)
                            }
                        }
                    }
                }

                authenticationCard(item, running: running)

                inspectorCard("Безопасность", systemImage: "lock.shield") {
                    Text("Для сохранённого профиля используются его SSH ID, password/Keychain и Touch ID-политика. Для ручного сервера пароль хранится только в macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func forwardingDiagram(_ item: IndependentPortForward, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Схема туннеля", systemImage: "network")
                    .font(.headline)
                Spacer()
                Label(running ? "Работает" : item.rule.kind.title, systemImage: running ? "checkmark.circle.fill" : item.rule.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(running ? Color.green : Color.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            HStack(spacing: 10) {
                switch item.rule.kind {
                case .local:
                    diagramNode("Ваш Mac", detail: "\(item.rule.bindAddress):\(item.rule.sourcePort)", icon: "laptopcomputer", running: running)
                    diagramConnector(label: "SSH", running: running)
                    diagramNode("SSH Server", detail: item.connection.displayLabel(profiles: sshProfiles), icon: "server.rack", running: running)
                    diagramConnector(label: "TCP", running: running)
                    diagramNode("Destination", detail: endpoint(item.rule.destinationHost, item.rule.destinationPort), icon: "network", running: running)
                case .remote:
                    diagramNode("Destination", detail: endpoint(item.rule.destinationHost, item.rule.destinationPort), icon: "network", running: running)
                    diagramConnector(label: "TCP", running: running)
                    diagramNode("SSH Server", detail: item.connection.displayLabel(profiles: sshProfiles), icon: "server.rack", running: running)
                    diagramConnector(label: "listen", running: running)
                    diagramNode("Remote port", detail: "\(item.rule.bindAddress):\(item.rule.sourcePort)", icon: "dot.radiowaves.left.and.right", running: running)
                case .dynamic:
                    diagramNode("Ваш Mac", detail: "SOCKS5 · \(item.rule.bindAddress):\(item.rule.sourcePort)", icon: "laptopcomputer", running: running)
                    diagramConnector(label: "SSH", running: running)
                    diagramNode("SSH Server", detail: item.connection.displayLabel(profiles: sshProfiles), icon: "server.rack", running: running)
                    diagramConnector(label: "SOCKS", running: running)
                    diagramNode("Сеть", detail: "динамический маршрут", icon: "globe", running: running)
                }
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private func diagramNode(_ title: String, detail: String, icon: String, running: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill((running ? Color.green : Color.accentColor).opacity(running ? (diagramPulse ? 0.22 : 0.10) : 0.13))
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(running ? Color.green : Color.accentColor)
            }
            .frame(width: 54, height: 54)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func diagramConnector(label: String, running: Bool) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                Rectangle().frame(height: 2)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
            }
            .foregroundStyle(running ? Color.green.opacity(diagramPulse ? 1.0 : 0.55) : Color.accentColor)
            Text(label)
                .font(.caption2)
                .foregroundStyle(running ? Color.green : Color.secondary)
        }
        .frame(width: 70)
    }

    @ViewBuilder
    private func authenticationCard(_ item: IndependentPortForward, running: Bool) -> some View {
        if item.connection.kind == .custom {
            inspectorCard("SSH-аутентификация", systemImage: "key.fill") {
                SecureField(
                    model.hasSavedForwardingPassword(item.id)
                        ? "Сохранён в Keychain — введите новый для замены"
                        : "Пароль SSH-сервера",
                    text: passwordBinding(for: item.id)
                )
                .textFieldStyle(.roundedBorder)
                .disabled(running)

                HStack {
                    Button("Сохранить в Keychain") {
                        let value = passwordInputs[item.id] ?? ""
                        guard !value.isEmpty else { return }
                        model.saveForwardingPassword(value, tunnelID: item.id)
                        passwordInputs[item.id] = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || (passwordInputs[item.id] ?? "").isEmpty)

                    if model.hasSavedForwardingPassword(item.id) {
                        Button("Исправить запись…") {
                            model.repairForwardingCredentialAccess(item.id)
                            passwordInputs[item.id] = ""
                        }
                        .disabled(running)
                        Spacer()
                        Button("Удалить пароль", role: .destructive) {
                            model.deleteSavedForwardingPassword(item.id)
                            passwordInputs[item.id] = ""
                        }
                        .disabled(running)
                    }
                }

                Toggle(
                    isOn: Binding(
                        get: { model.forwardingPasswordRequiresUserPresence(item.id) },
                        set: { model.setForwardingPasswordUserPresence($0, tunnelID: item.id) }
                    )
                ) {
                    Label("Требовать Touch ID перед использованием пароля", systemImage: "touchid")
                }
                .toggleStyle(.switch)
                .disabled(running)
            }
        } else {
            inspectorCard("SSH-аутентификация", systemImage: "key.fill") {
                Text("Аутентификация наследуется из выбранного сохранённого SSH-профиля.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inspectorCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private func endpoint(_ host: String, _ port: Int) -> String {
        let resolvedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "…" : host
        return "\(resolvedHost):\(port)"
    }

    private func shortKind(_ kind: PortForwardKind) -> String {
        switch kind {
        case .local: "L"
        case .remote: "R"
        case .dynamic: "D"
        }
    }

    private func tunnelSummary(_ item: IndependentPortForward) -> String {
        switch item.rule.kind {
        case .local:
            "Local :\(item.rule.sourcePort) → \(endpoint(item.rule.destinationHost, item.rule.destinationPort))"
        case .remote:
            "Remote :\(item.rule.sourcePort) → \(endpoint(item.rule.destinationHost, item.rule.destinationPort))"
        case .dynamic:
            "SOCKS5 \(item.rule.bindAddress):\(item.rule.sourcePort)"
        }
    }

    private func modeExplanation(_ kind: PortForwardKind) -> String {
        switch kind {
        case .local:
            "Local открывает порт на вашем Mac и отправляет трафик через SSH-сервер к указанному назначению."
        case .remote:
            "Remote открывает порт на SSH-сервере и передаёт входящий трафик через SSH к указанному назначению."
        case .dynamic:
            "Dynamic создаёт локальный SOCKS5-прокси; конечные адреса выбирает приложение-клиент."
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
