import SwiftUI

struct PortForwardingView: View {
    @EnvironmentObject private var model: AppModel
    let profile: ConnectionProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("SSH Port Forwarding") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(
                            "Туннели запускаются отдельными системными процессами SSH "
                                + "и работают, пока запущен \(AppBrand.name)."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Menu("Добавить", systemImage: "plus") {
                            ForEach(PortForwardKind.allCases) { kind in
                                Button(kind.title, systemImage: kind.systemImage) {
                                    model.addPortForward(kind)
                                }
                            }
                        }
                    }

                    if profile.portForwards.isEmpty {
                        ContentUnavailableView(
                            "Правил пока нет",
                            systemImage: "arrow.left.arrow.right",
                            description: Text(
                                "Добавьте локальный, удалённый или SOCKS-туннель."
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 230)
                    } else {
                        ForEach(profile.portForwards) { rule in
                            ruleEditor(rule)
                            if rule.id != profile.portForwards.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Что делает каждый режим") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Локальный: порт на Mac → host:port в сети SSH-сервера",
                        systemImage: "arrow.right"
                    )
                    Label(
                        "Удалённый: порт на SSH-сервере → host:port со стороны Mac",
                        systemImage: "arrow.left"
                    )
                    Label(
                        "SOCKS: локальный SOCKS5-прокси через SSH-сервер",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    Text(
                        "Для удалённого forwarding сервер может требовать AllowTcpForwarding "
                            + "и GatewayPorts. \(AppBrand.name) не меняет конфигурацию сервера."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func ruleEditor(_ rule: PortForwardRule) -> some View {
        let binding = binding(for: rule.id)
        let running = model.isSSHTunnelRunning(ruleID: rule.id)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Название правила", text: binding.name)
                    .font(.headline)
                    .textFieldStyle(.roundedBorder)
                    .disabled(running)
                if running {
                    Label("Активен", systemImage: "circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
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
                Button {
                    model.revealSSHTunnelLog(rule.id)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Показать журнал туннеля")
                Button(role: .destructive) {
                    model.removePortForward(rule.id)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(running)
            }

            Picker("Режим", selection: binding.kind) {
                ForEach(PortForwardKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(running)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(rule.kind == .remote ? "Слушать на сервере" : "Слушать на Mac")
                    TextField("127.0.0.1", text: binding.bindAddress)
                        .textFieldStyle(.roundedBorder)
                        .disabled(running)
                    Text("Порт")
                    TextField("8080", value: binding.sourcePort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 105)
                        .disabled(running)
                }

                if rule.kind != .dynamic {
                    GridRow {
                        Text("Назначение")
                        TextField("127.0.0.1", text: binding.destinationHost)
                            .textFieldStyle(.roundedBorder)
                            .disabled(running)
                        Text("Порт")
                        TextField("80", value: binding.destinationPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 105)
                            .disabled(running)
                    }
                }
            }
        }
    }

    private func binding(for ruleID: UUID) -> Binding<PortForwardRule> {
        Binding(
            get: {
                model.selectedProfile.portForwards.first(where: { $0.id == ruleID })
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
}
