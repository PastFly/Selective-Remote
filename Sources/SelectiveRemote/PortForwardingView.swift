import SwiftUI

struct PortForwardingView: View {
    @EnvironmentObject private var model: AppModel
    let profile: ConnectionProfile

    @State private var selectedRuleID: UUID?
    @State private var diagramPulse = false

    private var currentProfile: ConnectionProfile {
        model.profiles.first(where: { $0.id == profile.id }) ?? profile
    }

    private var selectedRule: PortForwardRule? {
        let rules = currentProfile.portForwards
        guard let selectedRuleID else { return rules.first }
        return rules.first(where: { $0.id == selectedRuleID }) ?? rules.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if currentProfile.portForwards.isEmpty {
                emptyState
            } else {
                HSplitView {
                    ruleList
                        .frame(minWidth: 280, idealWidth: 330, maxWidth: 420)

                    if let rule = selectedRule {
                        ruleInspector(rule)
                            .frame(minWidth: 520)
                    } else {
                        ContentUnavailableView(
                            "Выберите туннель",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onAppear {
            ensureSelection()
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                diagramPulse = true
            }
        }
        .onChange(of: currentProfile.portForwards) { _, _ in
            ensureSelection()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ContentUnavailableView(
                "Туннелей пока нет",
                systemImage: "arrow.left.arrow.right",
                description: Text(
                    "Создайте Local, Remote или Dynamic/SOCKS-туннель для этого SSH-профиля."
                )
            )

            addTunnelMenu
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addTunnelMenu: some View {
        Menu {
            ForEach(PortForwardKind.allCases) { kind in
                Button {
                    model.addPortForward(kind)
                    selectedRuleID = model.selectedProfile.portForwards.last?.id
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
        } label: {
            Label("Новый туннель", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            HStack {
                addTunnelMenu
                Spacer()
                Text("\(currentProfile.portForwards.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            List(selection: $selectedRuleID) {
                ForEach(currentProfile.portForwards) { rule in
                    ruleRow(rule)
                        .tag(rule.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Label(
                    "Туннели относятся только к \(currentProfile.friendlyName)",
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }

    private func ruleRow(_ rule: PortForwardRule) -> some View {
        let running = model.isProfileSSHTunnelRunning(
            ruleID: rule.id,
            profileID: profile.id
        )

        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill((running ? Color.green : Color.accentColor).opacity(0.13))
                Text(shortKind(rule.kind))
                    .font(.headline.monospaced())
                    .foregroundStyle(running ? Color.green : Color.accentColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if running {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                    }
                }

                Text(ruleSummary(rule))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRuleID = rule.id
        }
        .onTapGesture(count: 2) {
            selectedRuleID = rule.id
            if !running {
                model.startSSHTunnel(rule.id)
            }
        }
        .contextMenu {
            if running {
                Button("Остановить", systemImage: "stop.fill", role: .destructive) {
                    model.stopSSHTunnel(rule.id)
                }
                Button("Перезапустить", systemImage: "arrow.clockwise") {
                    restart(rule.id)
                }
            } else {
                Button("Запустить", systemImage: "play.fill") {
                    model.startSSHTunnel(rule.id)
                }
            }

            Button("Показать журнал", systemImage: "doc.text.magnifyingglass") {
                model.revealSSHTunnelLog(rule.id)
            }

            Divider()

            Button("Удалить", systemImage: "trash", role: .destructive) {
                model.removePortForward(rule.id)
            }
            .disabled(running)
        }
    }

    private func ruleInspector(_ rule: PortForwardRule) -> some View {
        let running = model.isProfileSSHTunnelRunning(
            ruleID: rule.id,
            profileID: profile.id
        )
        let binding = binding(for: rule.id)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Название туннеля", text: binding.name)
                            .textFieldStyle(.plain)
                            .font(.title2.bold())
                            .disabled(running)

                        HStack(spacing: 7) {
                            Label(rule.kind.title, systemImage: rule.kind.systemImage)
                            Text("·")
                            Text(sshEndpoint)
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
                            model.stopSSHTunnel(rule.id)
                        }
                    } else {
                        Button("Запустить", systemImage: "play.fill") {
                            model.startSSHTunnel(rule.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Menu {
                        if running {
                            Button("Перезапустить", systemImage: "arrow.clockwise") {
                                restart(rule.id)
                            }
                        }
                        Button("Показать журнал", systemImage: "doc.text.magnifyingglass") {
                            model.revealSSHTunnelLog(rule.id)
                        }
                        Divider()
                        Button("Удалить туннель", systemImage: "trash", role: .destructive) {
                            model.removePortForward(rule.id)
                        }
                        .disabled(running)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                forwardingDiagram(rule, running: running)

                inspectorCard("Режим", systemImage: "arrow.triangle.branch") {
                    Picker("Режим", selection: binding.kind) {
                        Text("Local").tag(PortForwardKind.local)
                        Text("Remote").tag(PortForwardKind.remote)
                        Text("Dynamic").tag(PortForwardKind.dynamic)
                    }
                    .pickerStyle(.segmented)
                    .disabled(running)

                    Text(modeExplanation(rule.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                inspectorCard("SSH-сервер", systemImage: "server.rack") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sshEndpoint)
                                .font(.headline)
                            Text("Используется SSH-аутентификация этого профиля")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label("Профиль хоста", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                inspectorCard("Маршрут", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text(rule.kind == .remote ? "Слушать на сервере" : "Слушать на Mac")
                                .foregroundStyle(.secondary)
                            TextField("127.0.0.1", text: binding.bindAddress)
                                .textFieldStyle(.roundedBorder)
                                .disabled(running)
                            Text("Порт")
                                .foregroundStyle(.secondary)
                            TextField("8080", value: binding.sourcePort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .disabled(running)
                        }

                        if rule.kind != .dynamic {
                            GridRow {
                                Text("Назначение")
                                    .foregroundStyle(.secondary)
                                TextField("127.0.0.1", text: binding.destinationHost)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(running)
                                Text("Порт")
                                    .foregroundStyle(.secondary)
                                TextField("80", value: binding.destinationPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                    .disabled(running)
                            }
                        }
                    }
                }

                inspectorCard("SSH-аутентификация", systemImage: "key.fill") {
                    Text(
                        "Туннель использует способ входа, SSH ID, Touch ID, Keychain и Jump Host из профиля «\(currentProfile.friendlyName)»."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                inspectorCard("Область действия", systemImage: "rectangle.on.rectangle") {
                    Text(
                        "Это профильный туннель. Он отображается активным только в карточке этого SSH-хоста и не считается независимым туннелем раздела Forwarding."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func forwardingDiagram(_ rule: PortForwardRule, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Схема туннеля", systemImage: "network")
                    .font(.headline)
                Spacer()
                Label(
                    running ? "Работает" : rule.kind.title,
                    systemImage: running ? "checkmark.circle.fill" : rule.kind.systemImage
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(running ? Color.green : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    (running ? Color.green : Color.accentColor).opacity(0.12),
                    in: Capsule()
                )
            }

            HStack(spacing: 10) {
                switch rule.kind {
                case .local:
                    diagramNode(
                        "Ваш Mac",
                        detail: "\(rule.bindAddress):\(rule.sourcePort)",
                        icon: "laptopcomputer",
                        running: running
                    )
                    diagramConnector(label: "SSH", running: running)
                    diagramNode(
                        "SSH Server",
                        detail: sshEndpoint,
                        icon: "server.rack",
                        running: running
                    )
                    diagramConnector(label: "TCP", running: running)
                    diagramNode(
                        "Destination",
                        detail: endpoint(rule.destinationHost, rule.destinationPort),
                        icon: "network",
                        running: running
                    )

                case .remote:
                    diagramNode(
                        "Destination",
                        detail: endpoint(rule.destinationHost, rule.destinationPort),
                        icon: "network",
                        running: running
                    )
                    diagramConnector(label: "TCP", running: running)
                    diagramNode(
                        "SSH Server",
                        detail: sshEndpoint,
                        icon: "server.rack",
                        running: running
                    )
                    diagramConnector(label: "listen", running: running)
                    diagramNode(
                        "Remote port",
                        detail: "\(rule.bindAddress):\(rule.sourcePort)",
                        icon: "dot.radiowaves.left.and.right",
                        running: running
                    )

                case .dynamic:
                    diagramNode(
                        "Ваш Mac",
                        detail: "SOCKS5 · \(rule.bindAddress):\(rule.sourcePort)",
                        icon: "laptopcomputer",
                        running: running
                    )
                    diagramConnector(label: "SSH", running: running)
                    diagramNode(
                        "SSH Server",
                        detail: sshEndpoint,
                        icon: "server.rack",
                        running: running
                    )
                    diagramConnector(label: "SOCKS", running: running)
                    diagramNode(
                        "Сеть",
                        detail: "динамический маршрут",
                        icon: "globe",
                        running: running
                    )
                }
            }
        }
        .padding(18)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    running ? Color.green.opacity(0.20) : Color.primary.opacity(0.07)
                )
        }
    }

    private func diagramNode(
        _ title: String,
        detail: String,
        icon: String,
        running: Bool
    ) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        (running ? Color.green : Color.accentColor)
                            .opacity(running ? (diagramPulse ? 0.22 : 0.10) : 0.13)
                    )
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(running ? Color.green : Color.accentColor)
            }
            .frame(width: 54, height: 54)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

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
            .foregroundStyle(
                running
                    ? Color.green.opacity(diagramPulse ? 1.0 : 0.55)
                    : Color.accentColor
            )

            Text(label)
                .font(.caption2)
                .foregroundStyle(running ? Color.green : Color.secondary)
        }
        .frame(width: 70)
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
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private var sshEndpoint: String {
        let user = currentProfile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = user.isEmpty ? "" : "\(user)@"
        return "\(prefix)\(currentProfile.host):\(currentProfile.sshPort)"
    }

    private func endpoint(_ host: String, _ port: Int) -> String {
        "\(host):\(port)"
    }

    private func shortKind(_ kind: PortForwardKind) -> String {
        switch kind {
        case .local: "L"
        case .remote: "R"
        case .dynamic: "D"
        }
    }

    private func ruleSummary(_ rule: PortForwardRule) -> String {
        switch rule.kind {
        case .local:
            "Local :\(rule.sourcePort) → \(endpoint(rule.destinationHost, rule.destinationPort))"
        case .remote:
            "Remote :\(rule.sourcePort) → \(endpoint(rule.destinationHost, rule.destinationPort))"
        case .dynamic:
            "SOCKS5 \(rule.bindAddress):\(rule.sourcePort)"
        }
    }

    private func modeExplanation(_ kind: PortForwardKind) -> String {
        switch kind {
        case .local:
            "Local открывает порт на вашем Mac и отправляет трафик через SSH-сервер к указанному назначению."
        case .remote:
            "Remote открывает порт на SSH-сервере и передаёт трафик к назначению со стороны Mac."
        case .dynamic:
            "Dynamic создаёт локальный SOCKS5-прокси, который направляет подключения через SSH-сервер."
        }
    }

    private func binding(for ruleID: UUID) -> Binding<PortForwardRule> {
        Binding(
            get: {
                currentProfile.portForwards.first(where: { $0.id == ruleID })
                    ?? PortForwardRule()
            },
            set: { updated in
                model.mutateSelectedProfile { profile in
                    guard let index = profile.portForwards.firstIndex(where: {
                        $0.id == ruleID
                    }) else { return }
                    profile.portForwards[index] = updated
                }
            }
        )
    }

    private func ensureSelection() {
        let rules = currentProfile.portForwards
        if let selectedRuleID,
           rules.contains(where: { $0.id == selectedRuleID }) {
            return
        }
        selectedRuleID = rules.first?.id
    }

    private func restart(_ ruleID: UUID) {
        model.stopSSHTunnel(ruleID)
        Task { @MainActor in
            for _ in 0..<30 {
                if !model.isProfileSSHTunnelRunning(
                    ruleID: ruleID,
                    profileID: profile.id
                ) {
                    model.startSSHTunnel(ruleID)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
